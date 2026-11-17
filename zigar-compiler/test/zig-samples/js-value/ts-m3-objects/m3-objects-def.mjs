export default class DefaultSession {
  static activeCount = 0;

  constructor(user) {
    this.user = String(user);
    DefaultSession.activeCount += 1;
  }

  close() {
    DefaultSession.activeCount -= 1;
    return `closed:${this.user}`;
  }
}
