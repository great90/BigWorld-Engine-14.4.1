"""bw_site.py - Site-specific module (minimal stub).

This module is imported by Script::init() and allows site-specific
overrides. For this minimal test setup, it patches logging.Logger to
add the trace method expected by FantasyDemo scripts.
"""

import logging


def _logger_trace(self, msg, *args, **kwargs):
    """Trace-level log method. Maps to BigWorld.logTrace if available,
    otherwise falls back to debug."""
    try:
        import BigWorld
        if hasattr(BigWorld, 'logTrace'):
            BigWorld.logTrace('', msg % args if args else msg, '')
            return
    except Exception:
        pass
    self.debug(msg, *args, **kwargs)


def _logger_notice(self, msg, *args, **kwargs):
    """Notice-level log method. Maps to BigWorld.logNotice if available,
    otherwise falls back to info."""
    try:
        import BigWorld
        if hasattr(BigWorld, 'logNotice'):
            BigWorld.logNotice('', msg % args if args else msg, '')
            return
    except Exception:
        pass
    self.info(msg, *args, **kwargs)


# Add trace method to Logger if not present
if not hasattr(logging.Logger, 'trace'):
    logging.Logger.trace = _logger_trace

# Add notice method to Logger if not present
if not hasattr(logging.Logger, 'notice'):
    logging.Logger.notice = _logger_notice


def onPersonalityLoaded():
    """Called after the personality module is loaded."""
    pass
