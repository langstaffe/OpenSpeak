package files

import (
	"strings"
	"testing"
)

func TestOriginalNamePreservesDisplayNameAndExtension(t *testing.T) {
	name := OriginalName(`C:\tmp\音乐 文档 2026.final.zip`)
	if name != "音乐 文档 2026.final.zip" {
		t.Fatalf("OriginalName = %q", name)
	}
}

func TestSanitizeNamePreservesExtensionWhenTruncating(t *testing.T) {
	name := strings.Repeat("a", 220) + ".docx"
	safe := SanitizeName(name)
	if len([]rune(safe)) > 180 {
		t.Fatalf("SanitizeName length = %d", len([]rune(safe)))
	}
	if !strings.HasSuffix(safe, ".docx") {
		t.Fatalf("SanitizeName lost extension: %q", safe)
	}
}
