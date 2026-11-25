// 验证码识别 NAPI 封装：MNN + ddddocr 模型（字符集 8210，输出为 int32 类别索引）
//
// 算法严格对齐模型作者的参考实现（kekxv/ddddocr-mnn `OcrCaptcha.hpp`）：
//   1. 灰度 → /255 → (x-0.5)/0.5，即归一化到 [-1,1]；
//   2. 高度固定 64，**宽度按原图比例**计算（不是固定宽度）；
//   3. 输入张量宽度是**动态**的，必须 resizeTensor + resizeSession 才能跑；
//   4. 模型输出是 int32 的类别索引序列（不是 8210 维 logits），
//      逐项去重、跳过 0（blank），再用字符集映射成文字。
//
// 任何一步不符合预期都返回空串（交由上层转人工输入），绝不在原生层猜。
#include <node_api.h>

#include <algorithm>
#include <cmath>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include <MNN/Interpreter.hpp>
#include <MNN/Tensor.hpp>

namespace {

constexpr int kInputHeight = 64;
/** 宽度上限：模型宽度动态，过宽会显著增加耗时与内存，这里做个上界保护。 */
constexpr int kMaxInputWidth = 400;

std::shared_ptr<MNN::Interpreter> g_interpreter;
MNN::Session *g_session = nullptr;
std::vector<std::string> g_charset;
std::mutex g_mutex;
/** 最近一次识别的诊断信息（设备上拿不到 C++ 日志，只能回传给 JS 打印）。 */
std::string g_lastDebug;

std::string ShapeText(const std::vector<int> &shape) {
  std::string text;
  for (size_t i = 0; i < shape.size(); ++i) {
    text += (i == 0 ? "" : "x") + std::to_string(shape[i]);
  }
  return text;
}

std::string ReadString(napi_env env, napi_value value) {
  size_t length = 0;
  napi_get_value_string_utf8(env, value, nullptr, 0, &length);
  std::string text(length, '\0');
  napi_get_value_string_utf8(env, value, text.data(), length + 1, &length);
  text.resize(length);
  return text;
}

napi_value MakeBool(napi_env env, bool value) {
  napi_value result = nullptr;
  napi_get_boolean(env, value, &result);
  return result;
}

/** 按行拆字符集（首项是 CTC 的 blank，索引 0）。 */
void SplitCharset(const std::string &joined) {
  g_charset.clear();
  std::string current;
  for (char ch : joined) {
    if (ch == '\n') {
      // 容错：文件若是 CRLF，行尾的 '\r' 必须去掉，否则每个字都带着回车，
      // 解码出来的串长度不对、也会污染 UI。
      if (!current.empty() && current.back() == '\r') {
        current.pop_back();
      }
      g_charset.push_back(current);
      current.clear();
    } else {
      current.push_back(ch);
    }
  }
  if (!current.empty() && current.back() == '\r') {
    current.pop_back();
  }
  g_charset.push_back(current);
}

/** 双线性缩放（半像素中心对齐，与 PIL / OpenCV 的默认行为一致）。 */
void ResizeBilinear(const std::vector<unsigned char> &src, int sw, int sh,
                    std::vector<unsigned char> &dst, int dw, int dh) {
  dst.assign(static_cast<size_t>(dw) * dh, 255);
  for (int y = 0; y < dh; ++y) {
    const float fy = (static_cast<float>(y) + 0.5f) * sh / dh - 0.5f;
    int y0 = static_cast<int>(std::floor(fy));
    const float wy = fy - y0;
    int y1 = y0 + 1;
    y0 = std::max(0, std::min(y0, sh - 1));
    y1 = std::max(0, std::min(y1, sh - 1));
    for (int x = 0; x < dw; ++x) {
      const float fx = (static_cast<float>(x) + 0.5f) * sw / dw - 0.5f;
      int x0 = static_cast<int>(std::floor(fx));
      const float wx = fx - x0;
      int x1 = x0 + 1;
      x0 = std::max(0, std::min(x0, sw - 1));
      x1 = std::max(0, std::min(x1, sw - 1));
      const float v = (1 - wy) * ((1 - wx) * src[y0 * sw + x0] + wx * src[y0 * sw + x1]) +
                      wy * ((1 - wx) * src[y1 * sw + x0] + wx * src[y1 * sw + x1]);
      dst[static_cast<size_t>(y) * dw + x] =
          static_cast<unsigned char>(std::max(0.0f, std::min(255.0f, v + 0.5f)));
    }
  }
}

/**
 * 用指定前处理跑一次推理，返回解码串（不含校验）。
 *
 * @param pad      左右补的白边宽度（0 表示不补）
 * @param targetW  缩放后的宽度（高度固定 64）
 */
std::string RunOnce(const std::vector<unsigned char> &gray, int width, int height,
                    int pad, int targetW) {
  const int paddedWidth = width + pad * 2;
  std::vector<unsigned char> canvas(static_cast<size_t>(paddedWidth) * height, 255);
  for (int y = 0; y < height; ++y) {
    for (int x = 0; x < width; ++x) {
      canvas[static_cast<size_t>(y) * paddedWidth + x + pad] =
          gray[static_cast<size_t>(y) * width + x];
    }
  }
  std::vector<unsigned char> scaled;
  ResizeBilinear(canvas, paddedWidth, height, scaled, targetW, kInputHeight);

  MNN::Tensor *input = g_interpreter->getSessionInput(g_session, nullptr);
  const std::vector<int> inputDims{1, 1, kInputHeight, targetW};
  g_interpreter->resizeTensor(input, inputDims);
  g_interpreter->resizeSession(g_session);
  input = g_interpreter->getSessionInput(g_session, nullptr);
  const std::vector<int> realShape = input->shape();
  if (realShape.size() != 4 || realShape[3] != targetW) {
    return "";
  }

  std::shared_ptr<MNN::Tensor> inputHost(
      MNN::Tensor::create<float>(realShape, nullptr, MNN::Tensor::CAFFE));
  float *inputData = inputHost->host<float>();
  const size_t count = static_cast<size_t>(targetW) * kInputHeight;
  for (size_t i = 0; i < count; ++i) {
    const float normalized = static_cast<float>(scaled[i]) / 255.0f;
    inputData[i] = (normalized - 0.5f) / 0.5f;
  }
  input->copyFromHostTensor(inputHost.get());
  if (g_interpreter->runSession(g_session) != MNN::NO_ERROR) {
    return "";
  }

  MNN::Tensor *output = g_interpreter->getSessionOutput(g_session, nullptr);
  if (output == nullptr) {
    return "";
  }
  const halide_type_t outputType = output->getType();
  if (outputType.bits != 32 || outputType.code == halide_type_float) {
    return "";
  }
  std::shared_ptr<MNN::Tensor> outputHost(
      MNN::Tensor::create<int32_t>(output->shape(), nullptr, MNN::Tensor::CAFFE));
  output->copyToHostTensor(outputHost.get());
  const int32_t *indices = outputHost->host<int32_t>();
  const std::vector<int> &shape = outputHost->shape();
  if (shape.empty() || indices == nullptr) {
    return "";
  }
  size_t steps = 1;
  for (int dim : shape) {
    steps *= static_cast<size_t>(dim);
  }

  std::string answer;
  int previous = 0;
  for (size_t i = 0; i < steps; ++i) {
    const int index = indices[i];
    if (index == previous) {
      continue;
    }
    previous = index;
    if (index == 0) {
      continue;
    }
    if (index > 0 && index < static_cast<int>(g_charset.size())) {
      answer += g_charset[index];
    }
  }
  g_lastDebug += "[w=" + std::to_string(targetW) + ",pad=" + std::to_string(pad) +
                 "→" + answer + "]";
  return answer;
}

napi_value Init(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value args[2] = {nullptr, nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  if (argc < 2) {
    napi_throw_error(env, nullptr, "init(modelPath, charset) 需要两个参数");
    return nullptr;
  }
  const std::string modelPath = ReadString(env, args[0]);
  const std::string charset = ReadString(env, args[1]);

  std::lock_guard<std::mutex> lock(g_mutex);
  if (g_session != nullptr) {
    g_interpreter->releaseSession(g_session);
    g_session = nullptr;
  }
  g_interpreter.reset(MNN::Interpreter::createFromFile(modelPath.c_str()));
  if (g_interpreter == nullptr) {
    napi_throw_error(env, nullptr, "模型加载失败（路径无效或模型损坏）");
    return nullptr;
  }
  MNN::ScheduleConfig config;
  config.type = MNN_FORWARD_CPU;
  config.numThread = 2;
  MNN::BackendConfig backend;
  // 与参考实现一致：高精度优先
  backend.precision = MNN::BackendConfig::Precision_High;
  config.backendConfig = &backend;
  g_session = g_interpreter->createSession(config);
  if (g_session == nullptr) {
    napi_throw_error(env, nullptr, "推理会话创建失败");
    return nullptr;
  }
  SplitCharset(charset);
  return MakeBool(env, true);
}

napi_value Release(napi_env env, napi_callback_info info) {
  std::lock_guard<std::mutex> lock(g_mutex);
  if (g_interpreter != nullptr && g_session != nullptr) {
    g_interpreter->releaseSession(g_session);
    g_session = nullptr;
  }
  g_interpreter.reset();
  g_charset.clear();
  return MakeBool(env, true);
}

napi_value DebugInfo(napi_env env, napi_callback_info info) {
  std::lock_guard<std::mutex> lock(g_mutex);
  const std::string text = g_lastDebug;
  napi_value result = nullptr;
  napi_create_string_utf8(env, text.c_str(), text.size(), &result);
  return result;
}

/** 诊断：报告输入张量、输出张量与字符集规模，不跑推理。 */
napi_value Probe(napi_env env, napi_callback_info info) {
  std::lock_guard<std::mutex> lock(g_mutex);
  std::string desc;
  if (g_session == nullptr || g_interpreter == nullptr) {
    desc = "no-session";
  } else {
    MNN::Tensor *input = g_interpreter->getSessionInput(g_session, nullptr);
    const halide_type_t type = input->getType();
    desc = "in:code=" + std::to_string(static_cast<int>(type.code)) +
           ",bits=" + std::to_string(static_cast<int>(type.bits)) +
           ",shape=" + ShapeText(input->shape()) +
           ",charset=" + std::to_string(g_charset.size());
    const std::map<std::string, MNN::Tensor *> &outputs =
        g_interpreter->getSessionOutputAll(g_session);
    for (auto &entry : outputs) {
      desc += ",out(" + entry.first + ")=" + ShapeText(entry.second->shape());
    }
  }
  napi_value text = nullptr;
  napi_create_string_utf8(env, desc.c_str(), desc.size(), &text);
  return text;
}

napi_value Recognize(napi_env env, napi_callback_info info) {
  size_t argc = 3;
  napi_value args[3] = {nullptr, nullptr, nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  if (argc < 3) {
    napi_throw_error(env, nullptr, "recognize(rgba, width, height) 需要三个参数");
    return nullptr;
  }

  void *data = nullptr;
  size_t byteLength = 0;
  if (napi_get_arraybuffer_info(env, args[0], &data, &byteLength) != napi_ok || data == nullptr) {
    napi_throw_error(env, nullptr, "第一个参数必须是 ArrayBuffer");
    return nullptr;
  }
  int32_t width = 0;
  int32_t height = 0;
  napi_get_value_int32(env, args[1], &width);
  napi_get_value_int32(env, args[2], &height);
  if (width <= 0 || height <= 0 || byteLength < static_cast<size_t>(width) * height * 4) {
    napi_throw_error(env, nullptr, "像素缓冲区尺寸与宽高不匹配");
    return nullptr;
  }

  std::lock_guard<std::mutex> lock(g_mutex);
  if (g_session == nullptr || g_interpreter == nullptr) {
    return nullptr;
  }
  g_lastDebug.clear();

  // 1. RGBA → 灰度（参考实现不做补边，直接整图缩放）
  const auto *rgba = static_cast<const unsigned char *>(data);
  std::vector<unsigned char> gray(static_cast<size_t>(width) * height, 255);
  for (int y = 0; y < height; ++y) {
    for (int x = 0; x < width; ++x) {
      const size_t src = (static_cast<size_t>(y) * width + x) * 4;
      const float luma = 0.299f * rgba[src] + 0.587f * rgba[src + 1] + 0.114f * rgba[src + 2];
      gray[static_cast<size_t>(y) * width + x] =
          static_cast<unsigned char>(std::max(0.0f, std::min(255.0f, luma + 0.5f)));
    }
  }

  // 2. 多种前处理各跑一次，取第一个「6 位」的结果
  //
  // 为什么要多试：单张验证码对缩放宽度/是否补边很敏感，实测同一张图
  // 「按比例 160」只解出 5 位、换一种就能出 6 位。推理本身只要几十毫秒，
  // 多试一两种比让用户手打划算得多。
  const int aspectWidth = std::max(1, std::min(
      static_cast<int>(std::lround(static_cast<float>(width) * kInputHeight /
                                   static_cast<float>(height))),
      kMaxInputWidth));
  struct Attempt {
    int pad;
    int targetW;
  };
  const Attempt attempts[3] = {{0, aspectWidth}, {5, 170}, {0, 170}};

  std::string best;
  for (const Attempt &attempt : attempts) {
    const std::string text = RunOnce(gray, width, height, attempt.pad, attempt.targetW);
    if (text.size() > best.size()) {
      best = text;
    }
    if (text.size() == 6) {
      best = text;
      break;
    }
  }

  napi_value result = nullptr;
  napi_create_string_utf8(env, best.c_str(), best.size(), &result);
  return result;
}

napi_value Register(napi_env env, napi_value exports) {
  napi_property_descriptor desc[] = {
      {"init", nullptr, Init, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"recognize", nullptr, Recognize, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"probe", nullptr, Probe, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"debug", nullptr, DebugInfo, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"release", nullptr, Release, nullptr, nullptr, nullptr, napi_default, nullptr},
  };
  napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
  return exports;
}

napi_module g_module = {
    1,            // nm_version
    0,            // nm_flags
    nullptr,      // nm_filename
    Register,     // nm_register_func
    "mnncaptcha", // nm_modname
    nullptr,      // nm_priv
    {0},          // reserved
};

}  // namespace

extern "C" __attribute__((constructor)) void RegisterMnnCaptchaModule() {
  napi_module_register(&g_module);
}
