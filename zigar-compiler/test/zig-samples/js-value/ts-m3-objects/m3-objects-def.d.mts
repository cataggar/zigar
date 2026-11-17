export default class DefaultSession {
  readonly user: string;
  static activeCount: number;
  constructor(user: string);
  close(): string;
}
