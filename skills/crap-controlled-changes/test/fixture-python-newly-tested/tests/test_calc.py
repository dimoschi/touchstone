from calc import branchy


def test_branchy():
    assert branchy(200) == "huge"
    assert branchy(50) == "big"
    assert branchy(42) == "answer"
    assert branchy(1) == "small"
