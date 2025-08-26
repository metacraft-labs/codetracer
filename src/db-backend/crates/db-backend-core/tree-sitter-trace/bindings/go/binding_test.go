package tree_sitter_tracepoint_test

import (
	"testing"

	tree_sitter "github.com/tree-sitter/go-tree-sitter"
	tree_sitter_tracepoint "github.com/tree-sitter/tree-sitter-tracepoint/bindings/go"
)

func TestCanLoadGrammar(t *testing.T) {
	language := tree_sitter.NewLanguage(tree_sitter_tracepoint.Language())
	if language == nil {
		t.Errorf("Error loading Tracepoint grammar")
	}
}
