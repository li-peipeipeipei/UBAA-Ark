export const init: (modelPath: string, charset: string) => boolean;
export const probe: () => string;
export const debug: () => string;
export const recognize: (rgba: ArrayBuffer, width: number, height: number) => string;
export const release: () => boolean;
