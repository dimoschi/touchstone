package calc

import "testing"

func TestSimple(t *testing.T) {
	if Simple(2) != 3 {
		t.Fatal("Simple(2) should be 3")
	}
}

func TestBranchy(t *testing.T) {
	cases := map[int]string{-1: "neg", 0: "zero", 101: "big", 7: "ok"}
	for in, want := range cases {
		if got := Branchy(in); got != want {
			t.Fatalf("Branchy(%d) = %q, want %q", in, got, want)
		}
	}
}
