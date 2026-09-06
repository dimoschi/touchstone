package crapcheckfixture

import "testing"

func TestSimple(t *testing.T) {
	if Simple(2) != 3 {
		t.Fatal("Simple(2) should be 3")
	}
}
