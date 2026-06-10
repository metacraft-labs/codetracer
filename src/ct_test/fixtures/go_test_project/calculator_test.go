package ctm11go

import "testing"

func TestAdd(t *testing.T) {
	if Add(2, 3) != 5 {
		t.Fatalf("unexpected sum")
	}
}

func TestGrouped(t *testing.T) {
	t.Run("alpha", func(t *testing.T) {
		if Double(2) != 4 {
			t.Fatalf("bad alpha")
		}
	})
	t.Run("beta", func(t *testing.T) {
		if Double(3) != 6 {
			t.Fatalf("bad beta")
		}
	})
}

func BenchmarkDouble(b *testing.B) {
	for i := 0; i < b.N; i++ {
		_ = Double(i)
	}
}
