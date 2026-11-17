import { connection, socket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '../common/Logger';

/**
 * 校园网关可达性探测（对齐上游 `connection.rs::SystemGatewayProbe`）。
 *
 * 判据是**纯 TCP 层**的：解析 `gw.buaa.edu.cn` 并尝试连接其 80 端口。
 *
 *   1. 只有解析到 **`10.0.0.0/8`** 的 IPv4 地址才算校园网证据 ——
 *      代理的 fake-ip（如 `198.18.0.0/15`）会让任意 TCP 连接成功，
 *      只认私网网关地址才能把这种假象排除（上游注释原文照此实现）；
 *   2. 任一候选地址在预算内连通 → `CAMPUS`；
 *   3. 解析失败 / 无地址 / 只解析出其它地址 / 连接被拒或超时 → `OFF_CAMPUS`；
 *   4. 探测自身出错（系统 API 异常）→ `UNKNOWN`。
 *
 * 与上游一致的两个性质：
 * - **不发 HTTP/TLS 请求、不带任何凭据** —— 探测只是 TCP 握手，
 *   不会被登录墙、重定向或证书问题干扰，也不泄露会话；
 * - **单飞 + 3 秒缓存** —— 登录、启动、故障切换同时触发也只探一次；
 *   短 TTL 保证「刚切了网」时的下一次判断是新结果。
 */
export enum NetworkState {
  /** 至少一个 10.x 网关地址接受了 TCP 连接。 */
  CAMPUS = 'CAMPUS',
  /** 解析失败、无地址、连接失败或超时。 */
  OFF_CAMPUS = 'OFF_CAMPUS',
  /** 探测自身发生内部失败（不代表校外）。 */
  UNKNOWN = 'UNKNOWN'
}

/** 网关主机（上游固定为 `gw.buaa.edu.cn:80`）。 */
const GATEWAY_HOST: string = 'gw.buaa.edu.cn';
const GATEWAY_PORT: number = 80;

/** 单次探测总预算（含 DNS 与所有连接尝试），与上游 `resolve_route` 的 500ms 一致。 */
const PROBE_BUDGET_MS: number = 500;

/** 结果缓存 TTL，与上游 `DEFAULT_GATEWAY_CACHE_TTL`（3 秒）一致。 */
const CACHE_TTL_MS: number = 3000;

export class CampusProbe {
  /** 缓存的探测结果；`null` 表示无缓存。 */
  private static cached: NetworkState | null = null;
  private static cachedAt: number = 0;
  /** 单飞：并发调用共享同一次探测。 */
  private static inflight: Promise<NetworkState> | null = null;

  /**
   * 作废缓存（换网、手动切换、故障回退前调用）。
   *
   * 只丢结果，不打断进行中的探测 —— 进行中的那次完成后也不会写回新缓存
   * （见 `run()` 的 revision 检查），避免「旧网络的观测污染新网络的判断」。
   */
  static invalidate(): void {
    CampusProbe.cached = null;
    CampusProbe.cachedAt = 0;
    CampusProbe.revision++;
  }

  private static revision: number = 0;

  /**
   * 探测当前是否处在校园网。
   *
   * @param budgetMs 总预算（含 DNS），默认 500ms。
   * @returns 三态结论；本方法**不抛异常**（探测失败也是一种结论）。
   */
  static async probe(budgetMs: number = PROBE_BUDGET_MS): Promise<NetworkState> {
    const now: number = Date.now();
    if (CampusProbe.cached !== null && now - CampusProbe.cachedAt < CACHE_TTL_MS) {
      return CampusProbe.cached;
    }
    if (CampusProbe.inflight !== null) {
      return CampusProbe.inflight;
    }
    const revision: number = CampusProbe.revision;
    const task: Promise<NetworkState> = CampusProbe.run(budgetMs)
      .then((state: NetworkState): NetworkState => {
        CampusProbe.inflight = null;
        // 探测期间发生过 invalidate → 结果属于旧网络，只返回不写缓存
        if (revision === CampusProbe.revision) {
          CampusProbe.cached = state;
          CampusProbe.cachedAt = Date.now();
        }
        return state;
      })
      .catch((error: Error): NetworkState => {
        CampusProbe.inflight = null;
        Logger.warn('校园网探测内部失败：' + error.message);
        return NetworkState.UNKNOWN;
      });
    CampusProbe.inflight = task;
    return task;
  }

  /** 走一遍 DNS + TCP 的实际探测（预算内）。 */
  private static async run(budgetMs: number): Promise<NetworkState> {
    const deadline: number = Date.now() + budgetMs;
    // ① DNS 解析（受总预算约束）
    let addresses: connection.NetAddress[];
    try {
      addresses = await CampusProbe.withBudget(
        deadline, connection.getAddressesByName(GATEWAY_HOST));
    } catch (error) {
      const err = error as BusinessError;
      // 解析失败 / 超时 = 拿不到校园网证据；只有「系统 API 内部出错」才记 UNKNOWN
      if (err !== undefined && err !== null && err.code === 2100003) {
        return NetworkState.UNKNOWN;
      }
      return NetworkState.OFF_CAMPUS;
    }

    // ② 只认 10.0.0.0/8 的 IPv4 —— 排除代理 fake-ip（198.18.x 等）
    const targets: string[] = [];
    for (let i = 0; i < addresses.length; i++) {
      const ip: string = addresses[i].address;
      if (CampusProbe.isCampusGateway(ip)) {
        targets.push(ip);
      }
    }
    if (targets.length === 0) {
      return NetworkState.OFF_CAMPUS;
    }

    // ③ 逐个尝试 TCP 连接，用掉剩余预算
    for (let i = 0; i < targets.length; i++) {
      const remaining: number = deadline - Date.now();
      if (remaining <= 0) {
        return NetworkState.OFF_CAMPUS;
      }
      const ok: boolean = await CampusProbe.tryConnect(targets[i], remaining);
      if (ok) {
        return NetworkState.CAMPUS;
      }
    }
    return NetworkState.OFF_CAMPUS;
  }

  /** `10.0.0.0/8`：首字节为 10 的点分四段 IPv4。 */
  private static isCampusGateway(ip: string): boolean {
    const parts: string[] = ip.split('.');
    if (parts.length !== 4) {
      return false;
    }
    return parts[0] === '10';
  }

  /**
   * 一次 TCP 连接尝试（连通即关，不发任何数据）。
   *
   * `timeout` 用剩余预算，保证不把 500ms 总预算拖长。
   */
  private static async tryConnect(ip: string, timeoutMs: number): Promise<boolean> {
    let tcp: socket.TCPSocket | null = null;
    try {
      tcp = socket.constructTCPSocketInstance();
      const address: socket.NetAddress = { address: ip, port: GATEWAY_PORT };
      const options: socket.TCPConnectOptions = { address: address, timeout: timeoutMs };
      await tcp.connect(options);
      return true;
    } catch (error) {
      return false;
    } finally {
      if (tcp !== null) {
        try {
          tcp.close();
        } catch (ignore) {
          // 关闭失败无所谓，进程内 socket 会随引用释放
        }
      }
    }
  }

  /** 给任意 Promise 加截止时间（DNS 没有超时参数，只能外面兜）。 */
  private static async withBudget<T>(deadline: number, task: Promise<T>): Promise<T> {
    const remaining: number = deadline - Date.now();
    if (remaining <= 0) {
      throw new Error('probe budget exhausted');
    }
    let timer: number = -1;
    const timeout = new Promise<T>((_resolve: Function, reject: Function): void => {
      timer = setTimeout(() => {
        reject(new Error('probe timeout'));
      }, remaining);
    });
    try {
      return await Promise.race([task, timeout]);
    } finally {
      if (timer >= 0) {
        clearTimeout(timer);
      }
    }
  }
}
