"""Bound selected buffered responses in the pinned mitmproxy 12.3.1 HTTP layer.

The addon response hook runs after buffering. This per-stream guard runs before
each append and lets the engine keep streaming unrelated PDFs, videos and downloads.
"""
from mitmproxy import flow
from mitmproxy.proxy.layers import http


def install():
    original = http.HttpStream.state_consume_response_body
    if getattr(original, "filter_byte_limit", False):
        return

    def consume(stream, event):
        budget = stream.flow.metadata.get("bufferBudget")
        if (budget is None or not isinstance(event, http.ResponseData)
                or len(event.data) + len(stream.response_body_buf) <= budget):
            yield from original(stream, event)
            return
        stream.response_body_buf.clear()
        message = "Image response exceeded its reserved byte limit"
        stream.flow.error = flow.Error(message)
        yield http.HttpErrorHook(stream.flow)
        code = http.ErrorCode.RESPONSE_TOO_LARGE
        yield http.SendHttp(http.ResponseProtocolError(stream.stream_id, message, code), stream.context.client)
        yield http.SendHttp(http.RequestProtocolError(stream.stream_id, message, code), stream.context.server)
        stream.client_state = stream.server_state = stream.state_errored
        stream.flow.live = False

    consume.filter_byte_limit = True
    http.HttpStream.state_consume_response_body = consume
