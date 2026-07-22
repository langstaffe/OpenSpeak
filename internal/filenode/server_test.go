package filenode

import (
	"bytes"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestSignedUploadAndDownload(t *testing.T) {
	server := &Server{Root: t.TempDir(), Secret: "test-secret"}
	payload := []byte("external attachment payload")
	uploadURL, err := SignedURL("http://file-node", server.Secret, Ticket{Operation: "put", ObjectKey: "fil_test", ExpiresAt: time.Now().Add(time.Minute), MaxBytes: int64(len(payload)), Name: "music.flac", ContentType: "audio/flac"})
	if err != nil {
		t.Fatal(err)
	}
	upload := requestForURL(t, http.MethodPut, uploadURL, bytes.NewReader(payload))
	upload.ContentLength = int64(len(payload))
	uploadResponse := httptest.NewRecorder()
	server.ServeHTTP(uploadResponse, upload)
	if uploadResponse.Code != http.StatusOK {
		t.Fatalf("upload status = %d, body = %s", uploadResponse.Code, uploadResponse.Body.String())
	}

	downloadURL, err := SignedURL("http://file-node", server.Secret, Ticket{Operation: "get", ObjectKey: "fil_test", ExpiresAt: time.Now().Add(time.Minute), MaxBytes: int64(len(payload)), Name: "music.flac", ContentType: "audio/flac"})
	if err != nil {
		t.Fatal(err)
	}
	downloadResponse := httptest.NewRecorder()
	server.ServeHTTP(downloadResponse, requestForURL(t, http.MethodGet, downloadURL, nil))
	if downloadResponse.Code != http.StatusOK || !bytes.Equal(downloadResponse.Body.Bytes(), payload) {
		t.Fatalf("download status/body = %d/%q", downloadResponse.Code, downloadResponse.Body.Bytes())
	}
	if downloadResponse.Header().Get("X-OpenSpeak-SHA256") == "" {
		t.Fatal("download did not return stored SHA-256")
	}
}

func TestTicketRejectsExpiredAndOversizedUpload(t *testing.T) {
	server := &Server{Root: t.TempDir(), Secret: "test-secret"}
	expiredURL, err := SignedURL("http://file-node", server.Secret, Ticket{Operation: "put", ObjectKey: "expired", ExpiresAt: time.Now().Add(-time.Minute), MaxBytes: 1})
	if err != nil {
		t.Fatal(err)
	}
	expired := httptest.NewRecorder()
	server.ServeHTTP(expired, requestForURL(t, http.MethodPut, expiredURL, bytes.NewReader([]byte("x"))))
	if expired.Code != http.StatusForbidden {
		t.Fatalf("expired status = %d", expired.Code)
	}

	uploadURL, err := SignedURL("http://file-node", server.Secret, Ticket{Operation: "put", ObjectKey: "large", ExpiresAt: time.Now().Add(time.Minute), MaxBytes: 1})
	if err != nil {
		t.Fatal(err)
	}
	large := requestForURL(t, http.MethodPut, uploadURL, bytes.NewReader([]byte("xx")))
	large.ContentLength = 2
	largeResponse := httptest.NewRecorder()
	server.ServeHTTP(largeResponse, large)
	if largeResponse.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("large upload status = %d", largeResponse.Code)
	}
}

func TestSignedURLAllowsBrowserCORS(t *testing.T) {
	server := &Server{Root: t.TempDir(), Secret: "test-secret"}
	uploadURL, err := SignedURL("https://file-node", server.Secret, Ticket{
		Operation: "put", ObjectKey: "browser", ExpiresAt: time.Now().Add(time.Minute), MaxBytes: 10,
	})
	if err != nil {
		t.Fatal(err)
	}
	preflight := requestForURL(t, http.MethodOptions, uploadURL, nil)
	preflight.Header.Set("Origin", "https://openspeak.example")
	preflight.Header.Set("Access-Control-Request-Method", http.MethodPut)
	preflight.Header.Set("Access-Control-Request-Headers", "content-type")
	response := httptest.NewRecorder()
	server.ServeHTTP(response, preflight)
	if response.Code != http.StatusNoContent {
		t.Fatalf("preflight status = %d, body = %s", response.Code, response.Body.String())
	}
	if response.Header().Get("Access-Control-Allow-Origin") != "*" ||
		!strings.Contains(response.Header().Get("Access-Control-Allow-Methods"), http.MethodPut) {
		t.Fatalf("preflight headers = %v", response.Header())
	}
	upload := requestForURL(t, http.MethodPut, uploadURL, strings.NewReader("web"))
	upload.Header.Set("Origin", "https://openspeak.example")
	uploadResponse := httptest.NewRecorder()
	server.ServeHTTP(uploadResponse, upload)
	if uploadResponse.Code != http.StatusOK || uploadResponse.Header().Get("Access-Control-Allow-Origin") != "*" {
		t.Fatalf("upload response = %d, headers = %v", uploadResponse.Code, uploadResponse.Header())
	}
}

func TestCleanupRemovesOnlyUncommittedUploads(t *testing.T) {
	root := t.TempDir()
	server := &Server{Root: root, Secret: "test-secret"}
	upload := func(key string) {
		t.Helper()
		rawURL, err := SignedURL("http://file-node", server.Secret, Ticket{Operation: "put", ObjectKey: key, ExpiresAt: time.Now().Add(time.Minute), MaxBytes: 1})
		if err != nil {
			t.Fatal(err)
		}
		response := httptest.NewRecorder()
		server.ServeHTTP(response, requestForURL(t, http.MethodPut, rawURL, bytes.NewReader([]byte("x"))))
		if response.Code != http.StatusOK {
			t.Fatalf("upload %s status = %d", key, response.Code)
		}
	}
	upload("orphan")
	upload("kept")
	commitURL, err := SignedURL("http://file-node", server.Secret, Ticket{Operation: "get", ObjectKey: "kept", ExpiresAt: time.Now().Add(time.Minute), MaxBytes: 1, Commit: true})
	if err != nil {
		t.Fatal(err)
	}
	commit := httptest.NewRecorder()
	server.ServeHTTP(commit, requestForURL(t, http.MethodHead, commitURL, nil))
	if commit.Code != http.StatusOK {
		t.Fatalf("commit status = %d", commit.Code)
	}
	removed, err := server.CleanupOrphans(time.Now().Add(2 * time.Minute))
	if err != nil || removed != 1 {
		t.Fatalf("cleanup removed=%d err=%v", removed, err)
	}
	if _, err := os.Stat(filepath.Join(root, "orphan")); !os.IsNotExist(err) {
		t.Fatalf("orphan still exists: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, "kept")); err != nil {
		t.Fatalf("committed object was removed: %v", err)
	}
}

func requestForURL(t *testing.T, method, rawURL string, body io.Reader) *http.Request {
	t.Helper()
	parsed, err := url.Parse(rawURL)
	if err != nil {
		t.Fatal(err)
	}
	request := httptest.NewRequest(method, parsed.RequestURI(), body)
	request.Host = parsed.Host
	return request
}
