"""Reserve capacity before mitmproxy starts buffering an eligible body."""
class Admission:
    def __init__(self, capacity=48 * 1024 * 1024, max_flows=48):
        self.capacity = capacity
        self.max_flows = max_flows
        self.pending = {}
        self.used = 0

    def reserve(self, key, length):
        if key in self.pending or length <= 0:
            return False
        if len(self.pending) >= self.max_flows or self.used + length > self.capacity:
            return False
        self.pending[key] = length
        self.used += length
        return True

    def release(self, key):
        self.used -= self.pending.pop(key, 0)
