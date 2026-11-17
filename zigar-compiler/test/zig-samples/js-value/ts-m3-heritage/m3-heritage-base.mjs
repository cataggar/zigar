export class EventEmitter {
  #counts = new Map();

  constructor() {
    this.listenerTotal = 0;
  }

  on(event) {
    this.#counts.set(event, (this.#counts.get(event) ?? 0) + 1);
    this.listenerTotal += 1;
    return this;
  }

  emit(event) {
    return (this.#counts.get(event) ?? 0) > 0;
  }

  listenerCount(event) {
    return this.#counts.get(event) ?? 0;
  }

  augmentedTag() {
    return `aug:${this.listenerTotal}:rev=${EventEmitter.specRevision}`;
  }

  static defaultMaxListeners = 10;
  static specRevision = 49;

  static isEmitter(val) {
    return val instanceof EventEmitter;
  }
}

export class Stream extends EventEmitter {
  constructor() {
    super();
  }

  pipe(dest) {
    return `pipe:${dest}:listeners=${this.listenerTotal}`;
  }
}
