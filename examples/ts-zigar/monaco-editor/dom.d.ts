/// <reference no-default-lib="true"/>
/// <reference lib="esnext" />

/*!
 * Focused browser DOM declaration subset compatible with TypeScript 7.1 `lib.dom.d.ts` (Apache-2.0)
 * for generating strongly-typed `dom` + `monaco-editor` Zig 0.17 bindings via `zigar ts`.
 */

interface EventInit {
    bubbles?: boolean;
    cancelable?: boolean;
    composed?: boolean;
}

interface CustomEventInit<T = any> extends EventInit {
    detail?: T;
}

interface EventListenerOptions {
    capture?: boolean;
}

interface AddEventListenerOptions extends EventListenerOptions {
    once?: boolean;
    passive?: boolean;
}

interface EventListener {
    (evt: Event): void;
}

interface EventListenerObject {
    handleEvent(object: Event): void;
}

type EventListenerOrEventListenerObject = EventListener | EventListenerObject;

interface EventTarget {
    addEventListener(
        type: string,
        callback: EventListener | EventListenerObject | null,
        options?: AddEventListenerOptions | boolean,
    ): void;
    removeEventListener(
        type: string,
        callback: EventListener | EventListenerObject | null,
        options?: EventListenerOptions | boolean,
    ): void;
    dispatchEvent(event: Event): boolean;
}

declare var EventTarget: {
    prototype: EventTarget;
    new(): EventTarget;
};

interface Event {
    readonly bubbles: boolean;
    readonly cancelable: boolean;
    readonly composed: boolean;
    readonly currentTarget: EventTarget | null;
    readonly defaultPrevented: boolean;
    readonly eventPhase: number;
    readonly isTrusted: boolean;
    readonly target: EventTarget | null;
    readonly timeStamp: number;
    readonly type: string;
    preventDefault(): void;
    stopImmediatePropagation(): void;
    stopPropagation(): void;
}

declare var Event: {
    prototype: Event;
    new(type: string, eventInitDict?: EventInit): Event;
    readonly NONE: 0;
    readonly CAPTURING_PHASE: 1;
    readonly AT_TARGET: 2;
    readonly BUBBLING_PHASE: 3;
};

interface CustomEvent<T = any> extends Event {
    readonly detail: T;
}

declare var CustomEvent: {
    prototype: CustomEvent;
    new<T>(type: string, eventInitDict?: CustomEventInit<T>): CustomEvent<T>;
};

interface UIEventInit extends EventInit {
    detail?: number;
    view?: Window | null;
    /** @deprecated */
    which?: number;
}

interface UIEvent extends Event {
    readonly detail: number;
    readonly view: Window | null;
}

declare var UIEvent: {
    prototype: UIEvent;
    new(type: string, eventInitDict?: UIEventInit): UIEvent;
};

interface EventModifierInit extends UIEventInit {
    altKey?: boolean;
    ctrlKey?: boolean;
    metaKey?: boolean;
    modifierAltGraph?: boolean;
    modifierCapsLock?: boolean;
    modifierFn?: boolean;
    modifierFnLock?: boolean;
    modifierHyper?: boolean;
    modifierNumLock?: boolean;
    modifierScrollLock?: boolean;
    modifierSuper?: boolean;
    modifierSymbol?: boolean;
    modifierSymbolLock?: boolean;
    shiftKey?: boolean;
}

interface MouseEventInit extends EventModifierInit {
    button?: number;
    buttons?: number;
    clientX?: number;
    clientY?: number;
    movementX?: number;
    movementY?: number;
    relatedTarget?: EventTarget | null;
    screenX?: number;
    screenY?: number;
}

interface MouseEvent extends UIEvent {
    readonly altKey: boolean;
    readonly button: number;
    readonly buttons: number;
    readonly clientX: number;
    readonly clientY: number;
    readonly ctrlKey: boolean;
    readonly metaKey: boolean;
    readonly movementX: number;
    readonly movementY: number;
    readonly offsetX: number;
    readonly offsetY: number;
    readonly pageX: number;
    readonly pageY: number;
    readonly relatedTarget: EventTarget | null;
    readonly screenX: number;
    readonly screenY: number;
    readonly shiftKey: boolean;
    readonly x: number;
    readonly y: number;
    getModifierState(keyArg: string): boolean;
}

declare var MouseEvent: {
    prototype: MouseEvent;
    new(type: string, eventInitDict?: MouseEventInit): MouseEvent;
};

interface KeyboardEventInit extends EventModifierInit {
    /** @deprecated */
    charCode?: number;
    code?: string;
    isComposing?: boolean;
    key?: string;
    /** @deprecated */
    keyCode?: number;
    location?: number;
    repeat?: boolean;
}

interface KeyboardEvent extends UIEvent {
    readonly altKey: boolean;
    readonly code: string;
    readonly ctrlKey: boolean;
    readonly isComposing: boolean;
    readonly key: string;
    readonly location: number;
    readonly metaKey: boolean;
    readonly repeat: boolean;
    readonly shiftKey: boolean;
    getModifierState(keyArg: string): boolean;
}

declare var KeyboardEvent: {
    prototype: KeyboardEvent;
    new(type: string, eventInitDict?: KeyboardEventInit): KeyboardEvent;
    readonly DOM_KEY_LOCATION_STANDARD: 0x00;
    readonly DOM_KEY_LOCATION_LEFT: 0x01;
    readonly DOM_KEY_LOCATION_RIGHT: 0x02;
    readonly DOM_KEY_LOCATION_NUMPAD: 0x03;
};

interface FocusEventInit extends UIEventInit {
    relatedTarget?: EventTarget | null;
}

interface FocusEvent extends UIEvent {
    readonly relatedTarget: EventTarget | null;
}

declare var FocusEvent: {
    prototype: FocusEvent;
    new(type: string, eventInitDict?: FocusEventInit): FocusEvent;
};

interface DataTransfer {
    dropEffect: "none" | "copy" | "link" | "move";
    effectAllowed: "none" | "copy" | "copyLink" | "copyMove" | "link" | "linkMove" | "move" | "all" | "uninitialized";
    readonly types: ReadonlyArray<string>;
    clearData(format?: string): void;
    getData(format: string): string;
    setData(format: string, data: string): void;
}

declare var DataTransfer: {
    prototype: DataTransfer;
    new(): DataTransfer;
};

interface ClipboardEventInit extends EventInit {
    clipboardData?: DataTransfer | null;
}

interface ClipboardEvent extends Event {
    readonly clipboardData: DataTransfer | null;
}

declare var ClipboardEvent: {
    prototype: ClipboardEvent;
    new(type: string, eventInitDict?: ClipboardEventInit): ClipboardEvent;
};

interface ErrorEventInit extends EventInit {
    colno?: number;
    error?: any;
    filename?: string;
    lineno?: number;
    message?: string;
}

interface ErrorEvent extends Event {
    readonly colno: number;
    readonly error: any;
    readonly filename: string;
    readonly lineno: number;
    readonly message: string;
}

declare var ErrorEvent: {
    prototype: ErrorEvent;
    new(type: string, eventInitDict?: ErrorEventInit): ErrorEvent;
};

interface MessageEventInit<T = any> extends EventInit {
    data?: T;
    lastEventId?: string;
    origin?: string;
}

interface MessageEvent<T = any> extends Event {
    readonly data: T;
    readonly lastEventId: string;
    readonly origin: string;
}

declare var MessageEvent: {
    prototype: MessageEvent;
    new<T>(type: string, eventInitDict?: MessageEventInit<T>): MessageEvent<T>;
};

interface CloseEventInit extends EventInit {
    code?: number;
    reason?: string;
    wasClean?: boolean;
}

interface CloseEvent extends Event {
    readonly code: number;
    readonly reason: string;
    readonly wasClean: boolean;
}

declare var CloseEvent: {
    prototype: CloseEvent;
    new(type: string, eventInitDict?: CloseEventInit): CloseEvent;
};

interface DOMRectInit {
    height?: number;
    width?: number;
    x?: number;
    y?: number;
}

interface DOMRectReadOnly {
    readonly bottom: number;
    readonly height: number;
    readonly left: number;
    readonly right: number;
    readonly top: number;
    readonly width: number;
    readonly x: number;
    readonly y: number;
    toJSON(): any;
}

declare var DOMRectReadOnly: {
    prototype: DOMRectReadOnly;
    new(x?: number, y?: number, width?: number, height?: number): DOMRectReadOnly;
    fromRect(other?: DOMRectInit): DOMRectReadOnly;
};

interface DOMRect extends DOMRectReadOnly {
    height: number;
    width: number;
    x: number;
    y: number;
}

declare var DOMRect: {
    prototype: DOMRect;
    new(x?: number, y?: number, width?: number, height?: number): DOMRect;
    fromRect(other?: DOMRectInit): DOMRect;
};

interface DOMTokenList {
    readonly length: number;
    value: string;
    add(...tokens: string[]): void;
    contains(token: string): boolean;
    item(index: number): string | null;
    remove(...tokens: string[]): void;
    replace(token: string, newToken: string): boolean;
    toggle(token: string, force?: boolean): boolean;
    [index: number]: string;
}

interface CSSStyleDeclaration {
    cssText: string;
    readonly length: number;
    backgroundColor: string;
    border: string;
    color: string;
    display: string;
    fontFamily: string;
    fontSize: string;
    height: string;
    margin: string;
    overflow: string;
    padding: string;
    position: string;
    width: string;
    getPropertyPriority(property: string): string;
    getPropertyValue(property: string): string;
    item(index: number): string;
    removeProperty(property: string): string;
    setProperty(property: string, value: string | null, priority?: string): void;
}

interface NodeList {
    readonly length: number;
    item(index: number): Node | null;
    [index: number]: Node;
}

interface NodeListOf<TNode extends Node> extends NodeList {
    item(index: number): TNode;
    [index: number]: TNode;
}

interface HTMLCollectionBase {
    readonly length: number;
    item(index: number): Element | null;
    [index: number]: Element;
}

interface HTMLCollection extends HTMLCollectionBase {
    namedItem(name: string): Element | null;
}

interface HTMLCollectionOf<T extends Element> extends HTMLCollectionBase {
    item(index: number): T | null;
    namedItem(name: string): T | null;
    [index: number]: T;
}

interface Node extends EventTarget {
    readonly baseURI: string;
    readonly childNodes: NodeListOf<Node>;
    readonly firstChild: Node | null;
    readonly isConnected: boolean;
    readonly lastChild: Node | null;
    readonly nextSibling: Node | null;
    readonly nodeName: string;
    readonly nodeType: number;
    nodeValue: string | null;
    readonly ownerDocument: Document | null;
    readonly parentElement: Element | null;
    readonly parentNode: Node | null;
    readonly previousSibling: Node | null;
    textContent: string | null;
    appendChild<T extends Node>(node: T): T;
    cloneNode(subtree?: boolean): Node;
    contains(other: Node | null): boolean;
    hasChildNodes(): boolean;
    insertBefore<T extends Node>(node: T, child: Node | null): T;
    removeChild<T extends Node>(child: T): T;
    replaceChild<T extends Node>(node: Node, child: T): T;
}

declare var Node: {
    prototype: Node;
    new(): Node;
    readonly ELEMENT_NODE: 1;
    readonly ATTRIBUTE_NODE: 2;
    readonly TEXT_NODE: 3;
    readonly CDATA_SECTION_NODE: 4;
    readonly ENTITY_REFERENCE_NODE: 5;
    readonly ENTITY_NODE: 6;
    readonly PROCESSING_INSTRUCTION_NODE: 7;
    readonly COMMENT_NODE: 8;
    readonly DOCUMENT_NODE: 9;
    readonly DOCUMENT_TYPE_NODE: 10;
    readonly DOCUMENT_FRAGMENT_NODE: 11;
    readonly NOTATION_NODE: 12;
    readonly DOCUMENT_POSITION_DISCONNECTED: 0x01;
    readonly DOCUMENT_POSITION_PRECEDING: 0x02;
    readonly DOCUMENT_POSITION_FOLLOWING: 0x04;
    readonly DOCUMENT_POSITION_CONTAINS: 0x08;
    readonly DOCUMENT_POSITION_CONTAINED_BY: 0x10;
    readonly DOCUMENT_POSITION_IMPLEMENTATION_SPECIFIC: 0x20;
};

interface Element extends Node {
    readonly children: HTMLCollection;
    readonly classList: DOMTokenList;
    className: string;
    readonly clientHeight: number;
    readonly clientLeft: number;
    readonly clientTop: number;
    readonly clientWidth: number;
    readonly firstElementChild: Element | null;
    id: string;
    innerHTML: string;
    readonly lastElementChild: Element | null;
    readonly nextElementSibling: Element | null;
    outerHTML: string;
    readonly previousElementSibling: Element | null;
    readonly scrollHeight: number;
    scrollLeft: number;
    scrollTop: number;
    readonly scrollWidth: number;
    readonly tagName: string;
    append(...nodes: (Node | string)[]): void;
    closest(selectors: string): Element | null;
    getAttribute(qualifiedName: string): string | null;
    getBoundingClientRect(): DOMRect;
    getElementsByClassName(classNames: string): HTMLCollectionOf<Element>;
    getElementsByTagName(qualifiedName: string): HTMLCollectionOf<Element>;
    hasAttribute(qualifiedName: string): boolean;
    matches(selectors: string): boolean;
    prepend(...nodes: (Node | string)[]): void;
    querySelector(selectors: string): Element | null;
    querySelectorAll(selectors: string): NodeListOf<Element>;
    remove(): void;
    removeAttribute(qualifiedName: string): void;
    setAttribute(qualifiedName: string, value: string): void;
    toggleAttribute(qualifiedName: string, force?: boolean): boolean;
}

declare var Element: {
    prototype: Element;
    new(): Element;
};

interface DOMStringMap {
    [name: string]: string | undefined;
}

interface HTMLElement extends Element {
    accessKey: string;
    contentEditable: string;
    readonly dataset: DOMStringMap;
    dir: string;
    draggable: boolean;
    hidden: boolean;
    innerText: string;
    readonly isContentEditable: boolean;
    lang: string;
    readonly offsetHeight: number;
    readonly offsetLeft: number;
    readonly offsetParent: Element | null;
    readonly offsetTop: number;
    readonly offsetWidth: number;
    readonly style: CSSStyleDeclaration;
    tabIndex: number;
    title: string;
    onclick: ((this: HTMLElement, ev: MouseEvent) => any) | null;
    ondblclick: ((this: HTMLElement, ev: MouseEvent) => any) | null;
    onkeydown: ((this: HTMLElement, ev: KeyboardEvent) => any) | null;
    onkeyup: ((this: HTMLElement, ev: KeyboardEvent) => any) | null;
    onmousedown: ((this: HTMLElement, ev: MouseEvent) => any) | null;
    onmousemove: ((this: HTMLElement, ev: MouseEvent) => any) | null;
    onmouseup: ((this: HTMLElement, ev: MouseEvent) => any) | null;
    onfocus: ((this: HTMLElement, ev: FocusEvent) => any) | null;
    onblur: ((this: HTMLElement, ev: FocusEvent) => any) | null;
    oninput: ((this: HTMLElement, ev: Event) => any) | null;
    onchange: ((this: HTMLElement, ev: Event) => any) | null;
    blur(): void;
    click(): void;
    focus(): void;
}

declare var HTMLElement: {
    prototype: HTMLElement;
    new(): HTMLElement;
};

interface HTMLDivElement extends HTMLElement {}

declare var HTMLDivElement: {
    prototype: HTMLDivElement;
    new(): HTMLDivElement;
};

interface HTMLSpanElement extends HTMLElement {}

declare var HTMLSpanElement: {
    prototype: HTMLSpanElement;
    new(): HTMLSpanElement;
};

interface HTMLHeadElement extends HTMLElement {}

declare var HTMLHeadElement: {
    prototype: HTMLHeadElement;
    new(): HTMLHeadElement;
};

interface HTMLButtonElement extends HTMLElement {
    disabled: boolean;
    name: string;
    type: "submit" | "reset" | "button";
    value: string;
}

declare var HTMLButtonElement: {
    prototype: HTMLButtonElement;
    new(): HTMLButtonElement;
};

interface HTMLInputElement extends HTMLElement {
    checked: boolean;
    disabled: boolean;
    name: string;
    placeholder: string;
    readOnly: boolean;
    required: boolean;
    type: string;
    value: string;
    select(): void;
}

declare var HTMLInputElement: {
    prototype: HTMLInputElement;
    new(): HTMLInputElement;
};

interface HTMLTextAreaElement extends HTMLElement {
    cols: number;
    disabled: boolean;
    name: string;
    placeholder: string;
    readOnly: boolean;
    required: boolean;
    rows: number;
    value: string;
    select(): void;
}

declare var HTMLTextAreaElement: {
    prototype: HTMLTextAreaElement;
    new(): HTMLTextAreaElement;
};

interface HTMLSelectElement extends HTMLElement {
    disabled: boolean;
    multiple: boolean;
    name: string;
    required: boolean;
    selectedIndex: number;
    value: string;
}

declare var HTMLSelectElement: {
    prototype: HTMLSelectElement;
    new(): HTMLSelectElement;
};

interface HTMLCanvasElement extends HTMLElement {
    height: number;
    width: number;
    toDataURL(type?: string, quality?: any): string;
}

declare var HTMLCanvasElement: {
    prototype: HTMLCanvasElement;
    new(): HTMLCanvasElement;
};

type WindowProxy = Window;

interface HTMLIFrameElement extends HTMLElement {
    readonly contentDocument: Document | null;
    readonly contentWindow: Window | null;
    height: string;
    name: string;
    src: string;
    srcdoc: string;
    width: string;
}

declare var HTMLIFrameElement: {
    prototype: HTMLIFrameElement;
    new(): HTMLIFrameElement;
};

interface DocumentFragment extends Node {}

interface Text extends Node {
    readonly wholeText: string;
    data: string;
    readonly length: number;
}

interface Document extends Node {
    readonly activeElement: Element | null;
    body: HTMLElement;
    readonly defaultView: Window | null;
    readonly documentElement: HTMLElement;
    readonly head: HTMLHeadElement;
    readonly readyState: "loading" | "interactive" | "complete";
    title: string;
    readonly URL: string;
    createDocumentFragment(): DocumentFragment;
    createElement(tagName: "div"): HTMLDivElement;
    createElement(tagName: "span"): HTMLSpanElement;
    createElement(tagName: "button"): HTMLButtonElement;
    createElement(tagName: "input"): HTMLInputElement;
    createElement(tagName: "textarea"): HTMLTextAreaElement;
    createElement(tagName: "select"): HTMLSelectElement;
    createElement(tagName: "canvas"): HTMLCanvasElement;
    createElement(tagName: "iframe"): HTMLIFrameElement;
    createElement(tagName: string): HTMLElement;
    createTextNode(data: string): Text;
    getElementById(elementId: string): HTMLElement | null;
    getElementsByClassName(classNames: string): HTMLCollectionOf<Element>;
    getElementsByTagName(qualifiedName: string): HTMLCollectionOf<Element>;
    hasFocus(): boolean;
    querySelector(selectors: string): Element | null;
    querySelectorAll(selectors: string): NodeListOf<Element>;
}

declare var Document: {
    prototype: Document;
    new(): Document;
};

interface URLSearchParams {
    readonly size: number;
    append(name: string, value: string): void;
    delete(name: string, value?: string): void;
    get(name: string): string | null;
    getAll(name: string): string[];
    has(name: string, value?: string): boolean;
    set(name: string, value: string): void;
    sort(): void;
    toString(): string;
}

declare var URLSearchParams: {
    prototype: URLSearchParams;
    new(init?: string | Record<string, string> | URLSearchParams): URLSearchParams;
};

interface URL {
    hash: string;
    host: string;
    hostname: string;
    href: string;
    readonly origin: string;
    password: string;
    pathname: string;
    port: string;
    protocol: string;
    search: string;
    readonly searchParams: URLSearchParams;
    username: string;
    toJSON(): string;
    toString(): string;
}

declare var URL: {
    prototype: URL;
    new(url: string | URL, base?: string | URL): URL;
    canParse(url: string | URL, base?: string | URL): boolean;
    createObjectURL(obj: Blob): string;
    parse(url: string | URL, base?: string | URL): URL | null;
    revokeObjectURL(url: string): void;
};

interface BlobPropertyBag {
    endings?: "transparent" | "native";
    type?: string;
}

type BufferSource = ArrayBufferView | ArrayBuffer;
type BlobPart = ArrayBufferView | ArrayBuffer | Blob | string;

interface Blob {
    readonly size: number;
    readonly type: string;
    arrayBuffer(): Promise<ArrayBuffer>;
    slice(start?: number, end?: number, contentType?: string): Blob;
    text(): Promise<string>;
}

declare var Blob: {
    prototype: Blob;
    new(blobParts?: (ArrayBufferView | ArrayBuffer | Blob | string)[], options?: BlobPropertyBag): Blob;
};

interface WebSocket extends EventTarget {
    binaryType: "blob" | "arraybuffer";
    readonly bufferedAmount: number;
    readonly extensions: string;
    onclose: ((this: WebSocket, ev: CloseEvent) => any) | null;
    onerror: ((this: WebSocket, ev: Event) => any) | null;
    onmessage: ((this: WebSocket, ev: MessageEvent) => any) | null;
    onopen: ((this: WebSocket, ev: Event) => any) | null;
    readonly protocol: string;
    readonly readyState: number;
    readonly url: string;
    close(code?: number, reason?: string): void;
    send(data: string | ArrayBufferLike | Blob | ArrayBufferView): void;
}

declare var WebSocket: {
    prototype: WebSocket;
    new(url: string | URL, protocols?: string | string[]): WebSocket;
    readonly CONNECTING: 0;
    readonly OPEN: 1;
    readonly CLOSING: 2;
    readonly CLOSED: 3;
};

interface Location {
    hash: string;
    host: string;
    hostname: string;
    href: string;
    readonly origin: string;
    pathname: string;
    port: string;
    protocol: string;
    search: string;
    assign(url: string | URL): void;
    reload(): void;
    replace(url: string | URL): void;
}

interface History {
    readonly length: number;
    readonly state: any;
    back(): void;
    forward(): void;
    go(delta?: number): void;
    pushState(data: any, unused: string, url?: string | URL | null): void;
    replaceState(data: any, unused: string, url?: string | URL | null): void;
}

interface Storage {
    readonly length: number;
    clear(): void;
    getItem(key: string): string | null;
    key(index: number): string | null;
    removeItem(key: string): void;
    setItem(key: string, value: string): void;
}

interface Navigator {
    readonly hardwareConcurrency: number;
    readonly language: string;
    readonly languages: readonly string[];
    readonly maxTouchPoints: number;
    readonly onLine: boolean;
    readonly userAgent: string;
}

interface MediaQueryList extends EventTarget {
    readonly matches: boolean;
    readonly media: string;
    onchange: ((this: MediaQueryList, ev: MediaQueryListEvent) => any) | null;
}

interface MediaQueryListEvent extends Event {
    readonly matches: boolean;
    readonly media: string;
}

interface Console {
    debug(...data: any[]): void;
    error(...data: any[]): void;
    info(...data: any[]): void;
    log(...data: any[]): void;
    warn(...data: any[]): void;
}

interface Window extends EventTarget {
    readonly devicePixelRatio: number;
    readonly document: Document;
    readonly history: History;
    readonly innerHeight: number;
    readonly innerWidth: number;
    readonly localStorage: Storage;
    location: Location;
    name: string;
    readonly navigator: Navigator;
    readonly outerHeight: number;
    readonly outerWidth: number;
    readonly scrollX: number;
    readonly scrollY: number;
    readonly self: Window;
    readonly sessionStorage: Storage;
    readonly window: Window;
    cancelAnimationFrame(handle: number): void;
    clearInterval(id: number | undefined): void;
    clearTimeout(id: number | undefined): void;
    getComputedStyle(elt: Element, pseudoElt?: string | null): CSSStyleDeclaration;
    matchMedia(query: string): MediaQueryList;
    postMessage(message: any, targetOrigin: string): void;
    requestAnimationFrame(callback: (time: number) => void): number;
    scrollBy(x: number, y: number): void;
    scrollTo(x: number, y: number): void;
    setInterval(handler: (...args: any[]) => void, timeout?: number, ...arguments: any[]): number;
    setTimeout(handler: (...args: any[]) => void, timeout?: number, ...arguments: any[]): number;
}

declare var Window: {
    prototype: Window;
    new(): Window;
};

type WorkerType = "classic" | "module";
type RequestCredentials = "include" | "omit" | "same-origin";

interface WorkerOptions {
    credentials?: "include" | "omit" | "same-origin";
    name?: string;
    type?: "classic" | "module";
}

interface Worker extends EventTarget {
    onmessage: ((this: Worker, ev: MessageEvent) => any) | null;
    onmessageerror: ((this: Worker, ev: MessageEvent) => any) | null;
    onerror: ((this: Worker, ev: ErrorEvent) => any) | null;
    postMessage(message: any): void;
    terminate(): void;
}

declare var Worker: {
    prototype: Worker;
    new(scriptURL: string | URL, options?: WorkerOptions): Worker;
};

declare var window: Window;
declare var document: Document;
declare var navigator: Navigator;
declare var location: Location;
declare var history: History;
declare var localStorage: Storage;
declare var sessionStorage: Storage;
declare var console: Console;
