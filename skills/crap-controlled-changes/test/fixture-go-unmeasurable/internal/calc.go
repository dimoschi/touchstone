package calc

// Simple has cyclomatic complexity 1.
func Simple(x int) int {
	return x + 1
}

// Branchy has cyclomatic complexity 4 (1 + 3 ifs).
func Branchy(x int) string {
	if x < 0 {
		return "neg"
	}
	if x == 0 {
		return "zero"
	}
	if x > 100 {
		return "big"
	}
	return "ok"
}

func Unscored(x int) int {
	if x > 7 {
		return x * 2
	}
	return x
}
