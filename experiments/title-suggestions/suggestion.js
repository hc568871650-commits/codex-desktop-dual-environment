/* Original preview controller: host adapters must supply explicit dialog/thread identity. */
(function (root) {
  "use strict";
  class TitleSuggestions {
    constructor({request, cancel, render, readValue, writeValue}) {
      Object.assign(this, {request, cancel, render, readValue, writeValue});
      this.epoch = 0;
      this.current = null;
    }
    open(threadId, messages) {
      this.close();
      this.current = {threadId, messages, initial: this.readValue(), dirty: false};
      return this.generate(false);
    }
    input() { if (this.current) this.current.dirty = true; }
    close() {
      this.epoch++;
      if (this.current?.requestId) this.cancel(this.current.requestId);
      this.current = null;
      this.render({state: "closed"});
    }
    async generate(refresh = true) {
      if (!this.current) return;
      if (this.current.requestId) this.cancel(this.current.requestId);
      const epoch = ++this.epoch, session = this.current;
      const requestId = globalThis.crypto.randomUUID();
      session.requestId = requestId;
      session.suggestion = null;
      this.render({state: "loading"});
      try {
        const result = await this.request({requestId, threadId: session.threadId,
          messages: session.messages, currentTitle: session.initial, refresh});
        if (epoch !== this.epoch || this.current !== session) return;
        if (result.requestId !== requestId || result.threadId !== session.threadId) throw Error("identity_mismatch");
        if (typeof result.title !== "string" || result.title.length < 1 || result.title.length > 60) throw Error("invalid_title");
        session.requestId = null;
        session.suggestion = result.title;
        // Suggestions never modify native input automatically, even if pristine.
        this.render({state: "ready", title: result.title, cached: result.cached});
      } catch (error) {
        if (epoch !== this.epoch || this.current !== session) return;
        session.requestId = null;
        this.render({state: "error", error: error.message || "request_failed"});
      }
    }
    useSuggestion() {
      const session = this.current;
      if (!session?.suggestion) return false;
      // Once the user edits, a delayed suggestion can be copied but never replaces their work.
      if (session.dirty || this.readValue() !== session.initial) {
        this.render({state: "edited", title: session.suggestion});
        return false;
      }
      this.writeValue(session.suggestion);
      session.initial = session.suggestion;
      session.dirty = false;
      this.render({state: "applied", title: session.suggestion});
      return true;
    }
  }
  if (typeof module !== "undefined") module.exports = {TitleSuggestions};
  else root.TitleSuggestions = TitleSuggestions;
})(globalThis);
