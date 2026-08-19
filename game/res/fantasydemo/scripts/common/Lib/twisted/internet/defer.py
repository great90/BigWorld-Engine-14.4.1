# Minimal stub of twisted.internet.defer for BigWorld PyDeferred

import sys

class Deferred(object):
    """A minimal Deferred implementation that fires callbacks synchronously
    when callback()/errback() is called, or immediately if already fired.

    Supports chained Deferreds: if a callback returns another Deferred,
    the callback chain is paused until the returned Deferred fires."""

    def __init__(self):
        self._callbacks = []
        self.result = None
        self._fired = False
        self._paused = 0

    def pause(self):
        self._paused += 1

    def unpause(self):
        self._paused -= 1
        if self._paused <= 0:
            self._continueCallbacks()

    def addCallback(self, cb, *args, **kw):
        return self.addCallbacks(cb, None, callbackArgs=args,
                                 callbackKeywords=kw)

    def addErrback(self, eb, *args, **kw):
        return self.addCallbacks(None, eb, errbackArgs=args,
                                 errbackKeywords=kw)

    def addBoth(self, f, *args, **kw):
        return self.addCallbacks(f, f, callbackArgs=args,
                                 callbackKeywords=kw, errbackArgs=args,
                                 errbackKeywords=kw)

    def addCallbacks(self, callback=None, errback=None,
                     callbackArgs=None, callbackKeywords=None,
                     errbackArgs=None, errbackKeywords=None):
        self._callbacks.append((callback, errback, callbackArgs or (),
                                callbackKeywords or {},
                                errbackArgs or (), errbackKeywords or {}))
        if self._fired:
            self._continueCallbacks()
        return self

    def callback(self, result):
        if self._fired:
            raise RuntimeError("Already fired")
        self.result = result
        self._fired = True
        print "DEFER_DEBUG: callback fired, result type:", type(result).__name__, ", callbacks:", len(self._callbacks)
        self._continueCallbacks()

    def errback(self, failure=None):
        if self._fired:
            raise RuntimeError("Already fired")
        if failure is None:
            failure = Failure(Exception("errback called"))
        if not isinstance(failure, Failure):
            failure = Failure(failure)
        self.result = failure
        self._fired = True
        self._continueCallbacks()

    def _continueCallbacks(self):
        if self._paused > 0:
            return

        isErr = isinstance(self.result, Failure) or \
            isinstance(self.result, Exception)

        while self._callbacks and self._paused <= 0:
            cb, eb, cbArgs, cbKw, ebArgs, ebKw = self._callbacks.pop(0)
            print "DEFER_DEBUG: processing callback", getattr(cb, '__name__', None) or getattr(eb, '__name__', None), ", isErr:", isErr, ", remaining:", len(self._callbacks)
            try:
                if isErr:
                    if eb is not None:
                        r = eb(self.result, *ebArgs, **ebKw)
                        if r is not None:
                            self.result = r
                            isErr = isinstance(r, Failure) or \
                                isinstance(r, Exception)
                else:
                    if cb is not None:
                        r = cb(self.result, *cbArgs, **cbKw)
                        if r is not None:
                            self.result = r
                            isErr = isinstance(r, Failure) or \
                                isinstance(r, Exception)
            except Exception as e:
                print "DEFER_DEBUG: EXCEPTION in callback", getattr(cb, '__name__', None) or getattr(eb, '__name__', None), ":", type(e).__name__, str(e)
                self.result = Failure(e)
                isErr = True

            # If the result is a Deferred (or has callback/errback methods),
            # pause until it fires. Note: we check this even if _callbacks is
            # empty, because new callbacks may be added later via addCallbacks.
            if hasattr(self.result, 'addCallbacks') and \
                    hasattr(self.result, 'callback') and \
                    hasattr(self.result, 'errback') and \
                    not isinstance(self.result, Failure):
                inner = self.result
                self.pause()
                print "DEFER_DEBUG: chaining to inner Deferred, paused =", self._paused, ", remaining callbacks:", len(self._callbacks)
                # When inner fires, it should call our callback/errback
                def _onInnerCallback(result):
                    print "DEFER_DEBUG: _onInnerCallback called, result type:", type(result).__name__
                    self.result = result
                    self.unpause()
                    return result
                def _onInnerErrback(failure):
                    if not isinstance(failure, Failure):
                        failure = Failure(failure)
                    print "DEFER_DEBUG: _onInnerErrback called:", failure
                    self.result = failure
                    self.unpause()
                    return failure
                inner.addCallbacks(_onInnerCallback, _onInnerErrback)
                break


# Module-level helper functions (mirroring twisted.internet.defer API)

def succeed(result):
    """Create a Deferred that has already been fired with a success result."""
    d = Deferred()
    d.callback(result)
    return d

def fail(result=None):
    """Create a Deferred that has already been fired with a failure."""
    d = Deferred()
    d.errback(result)
    return d


# Late import to avoid circular dependency
from twisted.python.failure import Failure
