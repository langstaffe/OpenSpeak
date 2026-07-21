package realtime

import (
	"encoding/base64"
	"sync"
	"testing"
	"time"
)

func TestScreenShareVoiceStateAdmissionIsAtomic(t *testing.T) {
	hub := NewHub()
	start := make(chan struct{})
	results := make(chan bool, 2)
	var group sync.WaitGroup
	for _, userID := range []string{"usr_one", "usr_two"} {
		group.Add(1)
		go func() {
			defer group.Done()
			<-start
			_, accepted := hub.SetVoiceStateIfScreenAvailable(VoiceState{
				ServerID: "srv_test", UserID: userID, ChannelID: "chn_test", ScreenSharing: true,
			})
			results <- accepted
		}()
	}
	close(start)
	group.Wait()
	close(results)
	accepted := 0
	for result := range results {
		if result {
			accepted++
		}
	}
	if accepted != 1 {
		t.Fatalf("accepted screen sharers = %d, want 1", accepted)
	}
}

func TestSnapshotIncludesOnlineUsersCurrentChannel(t *testing.T) {
	hub := NewHub()
	now := time.Now().UTC()
	client := &Client{
		UserID: "usr_test", DisplayName: "Tester", DeviceID: "dev_test",
		ServerID: "srv_test", ConnectedAt: now, LastSeenAt: now,
	}
	hub.add(client)
	hub.currentChannel["srv_test"] = map[string]CurrentChannelState{
		"usr_test": {
			ServerID: "srv_test", UserID: "usr_test", ChannelID: "chn_test", UpdatedAt: now,
		},
	}

	snapshot := hub.Snapshot("srv_test")
	if len(snapshot.Users) != 1 {
		t.Fatalf("users = %d, want 1", len(snapshot.Users))
	}
	user := snapshot.Users[0]
	if user.CurrentChannelID == nil || *user.CurrentChannelID != "chn_test" {
		t.Fatalf("current channel = %#v", user.CurrentChannelID)
	}
}

func TestDirectE2EERejectsPlaintextAndTargetsWrappedDevices(t *testing.T) {
	hub := NewHub()
	hub.SetEncryptionModeLookup(func(string) (string, bool) { return "e2ee", true })
	now := time.Now().UTC()
	sender := &Client{
		UserID: "sender", DeviceID: "dev_sender", ServerID: "srv_test",
		IdentityPublicKey: "sender-identity", EnvelopePublicKey: "sender-envelope",
		ConnectedAt: now, LastSeenAt: now, send: make(chan Event, 1),
	}
	recipient := &Client{
		UserID: "recipient", DeviceID: "dev_recipient", ServerID: "srv_test",
		IdentityPublicKey: "recipient-identity", EnvelopePublicKey: "recipient-envelope",
		ConnectedAt: now, LastSeenAt: now, send: make(chan Event, 1),
	}
	hub.add(sender)
	hub.add(recipient)
	if _, ok := hub.SendDirectMessage(sender, Event{
		ToUser: "recipient", Payload: map[string]any{"kind": "text", "body": "plaintext"},
	}); ok {
		t.Fatal("e2ee server accepted plaintext direct message")
	}
	body := base64.RawURLEncoding.EncodeToString(make([]byte, 32))
	nonce := base64.RawURLEncoding.EncodeToString(make([]byte, 12))
	_, ok := hub.SendDirectMessage(sender, Event{
		ToUser: "recipient",
		Payload: map[string]any{
			"kind": "text", "body": body, "nonce": nonce,
			"message_id": "dm_0123456789abcdef01234567", "encryption_mode": "e2ee",
			"envelopes": []DirectKeyEnvelope{
				{Algorithm: "openspeak-envelope-v1", RecipientUserID: "sender", RecipientDeviceID: "dev_sender", Ciphertext: "sender-key"},
				{Algorithm: "openspeak-envelope-v1", RecipientUserID: "recipient", RecipientDeviceID: "dev_recipient", Ciphertext: "recipient-key"},
			},
		},
	})
	if !ok {
		t.Fatal("valid encrypted direct message was rejected")
	}
	for _, client := range []*Client{sender, recipient} {
		select {
		case event := <-client.send:
			if event.Payload["body"] != body || event.Payload["sender_identity_public_key"] != "sender-identity" {
				t.Fatalf("encrypted event = %#v", event.Payload)
			}
		default:
			t.Fatal("wrapped device did not receive encrypted event")
		}
	}
}

func TestDirectMessageCanOnlyBeDeletedByItsSender(t *testing.T) {
	hub := NewHub()
	hub.directMessages["dm_test"] = directMessageReference{
		ServerID: "srv_test", FromUser: "sender", ToUser: "recipient",
	}
	_, deleted := hub.DeleteDirectMessage(
		&Client{UserID: "recipient", ServerID: "srv_test"},
		Event{Payload: map[string]any{"message_id": "dm_test"}},
	)
	if deleted {
		t.Fatal("recipient deleted the sender's direct message")
	}
	if _, ok := hub.directMessages["dm_test"]; !ok {
		t.Fatal("unauthorized deletion removed the message reference")
	}
}
