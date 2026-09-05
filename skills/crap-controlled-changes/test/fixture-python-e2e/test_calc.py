from calc import add, branchy


def test_add():
    assert add(1, 2) == 3


def test_branchy():
    assert branchy(200) == "huge"
    assert branchy(50) == "big"
    assert branchy(1) == "small"
