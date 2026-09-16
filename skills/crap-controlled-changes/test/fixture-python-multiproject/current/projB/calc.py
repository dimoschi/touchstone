def add(a, b):
    return a + b


def branchy(x):
    if x > 100:
        return "huge"
    if x > 10:
        return "big"
    if x < 0:
        return "negative"
    return "small"
