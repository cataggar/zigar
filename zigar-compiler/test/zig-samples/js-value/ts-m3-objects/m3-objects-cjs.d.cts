declare class CjsSocket {
  readonly port: number;
  constructor(port: number);
  ref(): this;
  unref(): this;
  isRefed(): boolean;
}

export = CjsSocket;
