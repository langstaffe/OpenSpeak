package realtime

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"log/slog"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

type Event struct {
	Type      string         `json:"type"`
	ServerID  string         `json:"server_id,omitempty"`
	ChannelID string         `json:"channel_id,omitempty"`
	FromUser  string         `json:"from_user,omitempty"`
	ToUser    string         `json:"to_user,omitempty"`
	Payload   map[string]any `json:"payload,omitempty"`
	SentAt    time.Time      `json:"sent_at"`
}

type Client struct {
	UserID            string
	DisplayName       string
	DeviceID          string
	IdentityPublicKey string
	EnvelopePublicKey string
	OwnerDeviceID     string
	ServerID          string
	ConnectedAt       time.Time
	LastSeenAt        time.Time
	conn              *websocket.Conn
	send              chan Event
	hub               *Hub
}

type DirectDevice struct {
	ID                string `json:"id"`
	UserID            string `json:"user_id"`
	IdentityPublicKey string `json:"identity_public_key"`
	EnvelopePublicKey string `json:"envelope_public_key"`
}

type DirectKeyEnvelope struct {
	Algorithm         string `json:"algorithm"`
	RecipientUserID   string `json:"recipient_user_id"`
	RecipientDeviceID string `json:"recipient_device_id"`
	Ciphertext        string `json:"ciphertext"`
}

type DevicePresence struct {
	DeviceID    string    `json:"device_id"`
	ConnectedAt time.Time `json:"connected_at"`
	LastSeenAt  time.Time `json:"last_seen_at"`
}

type UserPresence struct {
	UserID           string           `json:"user_id"`
	DisplayName      string           `json:"display_name"`
	AvatarVersion    int64            `json:"avatar_version"`
	Role             string           `json:"role,omitempty"`
	Online           bool             `json:"online"`
	CurrentChannelID *string          `json:"current_channel_id,omitempty"`
	Devices          []DevicePresence `json:"devices"`
	LastSeenAt       time.Time        `json:"last_seen_at"`
}

type CurrentChannelState struct {
	ServerID  string    `json:"server_id"`
	UserID    string    `json:"user_id"`
	ChannelID string    `json:"channel_id"`
	UpdatedAt time.Time `json:"updated_at"`
}

type VoiceState struct {
	ServerID               string    `json:"server_id"`
	UserID                 string    `json:"user_id"`
	DisplayName            string    `json:"display_name"`
	ChannelID              string    `json:"channel_id"`
	Muted                  bool      `json:"muted"`
	Deafened               bool      `json:"deafened"`
	Speaking               bool      `json:"speaking"`
	ScreenSharing          bool      `json:"screen_sharing"`
	ScreenShareResolution  string    `json:"screen_share_resolution,omitempty"`
	ScreenShareFPS         int       `json:"screen_share_fps,omitempty"`
	ScreenShareMediaNodeID string    `json:"screen_share_media_node_id,omitempty"`
	UpdatedAt              time.Time `json:"updated_at"`
}

type PresenceSnapshot struct {
	ServerID    string         `json:"server_id"`
	Users       []UserPresence `json:"users"`
	VoiceStates []VoiceState   `json:"voice_states"`
}

type directMessageReference struct {
	ServerID string
	FromUser string
	ToUser   string
	FileID   string
}

type Hub struct {
	register       chan *Client
	unregister     chan *Client
	publish        chan Event
	mu             sync.RWMutex
	clients        map[*Client]struct{}
	byUser         map[string]map[*Client]struct{}
	byServer       map[string]map[*Client]struct{}
	currentChannel map[string]map[string]CurrentChannelState
	voiceState     map[string]map[string]VoiceState
	directMessages map[string]directMessageReference
	userOffline    func(serverID, userID string)
	directDeleted  func(fileID string)
	authorize      func(serverID, userID, permission string) bool
	encryptionMode func(serverID string) (string, bool)
}

func NewHub() *Hub {
	return &Hub{
		register:       make(chan *Client),
		unregister:     make(chan *Client),
		publish:        make(chan Event, 256),
		clients:        make(map[*Client]struct{}),
		byUser:         make(map[string]map[*Client]struct{}),
		byServer:       make(map[string]map[*Client]struct{}),
		currentChannel: make(map[string]map[string]CurrentChannelState),
		voiceState:     make(map[string]map[string]VoiceState),
		directMessages: make(map[string]directMessageReference),
	}
}

func (h *Hub) Run(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			h.closeAll()
			return
		case client := <-h.register:
			for _, event := range h.add(client) {
				h.deliver(event)
			}
		case client := <-h.unregister:
			for _, event := range h.remove(client) {
				h.deliver(event)
			}
		case event := <-h.publish:
			h.deliver(event)
		}
	}
}

func (h *Hub) Attach(conn *websocket.Conn, userID, displayName string, device DirectDevice, ownerDeviceID, serverID string) {
	now := time.Now().UTC()
	client := &Client{
		UserID:            userID,
		DisplayName:       displayName,
		DeviceID:          device.ID,
		IdentityPublicKey: device.IdentityPublicKey,
		EnvelopePublicKey: device.EnvelopePublicKey,
		OwnerDeviceID:     ownerDeviceID,
		ServerID:          serverID,
		ConnectedAt:       now,
		LastSeenAt:        now,
		conn:              conn,
		send:              make(chan Event, 32),
		hub:               h,
	}
	h.register <- client
	go client.writeLoop()
	client.readLoop()
}

func (h *Hub) OwnerDeviceOnline(serverID, ownerDeviceID string) bool {
	h.mu.RLock()
	defer h.mu.RUnlock()
	for client := range h.byServer[serverID] {
		if client.OwnerDeviceID == ownerDeviceID {
			return true
		}
	}
	return false
}

func (h *Hub) DeviceOnlineInServer(serverID, deviceID string) bool {
	h.mu.RLock()
	defer h.mu.RUnlock()
	for client := range h.byServer[serverID] {
		if client.DeviceID == deviceID {
			return true
		}
	}
	return false
}

func (h *Hub) DisconnectOwnerDevice(serverID, ownerDeviceID, eventType string) {
	h.mu.RLock()
	targets := make([]*Client, 0)
	for client := range h.byServer[serverID] {
		if client.OwnerDeviceID == ownerDeviceID {
			targets = append(targets, client)
			event := stamp(Event{
				Type:     eventType,
				ServerID: serverID,
				Payload:  map[string]any{"owner_device_id": ownerDeviceID},
			})
			select {
			case client.send <- event:
			default:
			}
		}
	}
	h.mu.RUnlock()
	for _, client := range targets {
		time.AfterFunc(50*time.Millisecond, func() {
			_ = client.conn.Close()
		})
	}
}

func (h *Hub) DisconnectAllOwnerDevices(serverID, eventType string) {
	h.mu.RLock()
	deviceIDs := map[string]struct{}{}
	for client := range h.byServer[serverID] {
		if client.OwnerDeviceID != "" {
			deviceIDs[client.OwnerDeviceID] = struct{}{}
		}
	}
	h.mu.RUnlock()
	for deviceID := range deviceIDs {
		h.DisconnectOwnerDevice(serverID, deviceID, eventType)
	}
}

func (h *Hub) DisconnectOwnerUser(serverID, ownerUserID, eventType string) {
	h.mu.RLock()
	targets := make([]*Client, 0)
	for client := range h.byServer[serverID] {
		if client.UserID == ownerUserID {
			targets = append(targets, client)
			event := stamp(Event{
				Type:     eventType,
				ServerID: serverID,
				Payload:  map[string]any{"owner_device_id": client.OwnerDeviceID},
			})
			select {
			case client.send <- event:
			default:
			}
		}
	}
	h.mu.RUnlock()
	for _, client := range targets {
		time.AfterFunc(50*time.Millisecond, func() {
			_ = client.conn.Close()
		})
	}
}

func (h *Hub) DisconnectUser(serverID, userID, eventType string) {
	h.mu.RLock()
	targets := make([]*Client, 0)
	for client := range h.byServer[serverID] {
		if client.UserID != userID {
			continue
		}
		targets = append(targets, client)
		event := stamp(Event{
			Type:     eventType,
			ServerID: serverID,
			FromUser: userID,
		})
		select {
		case client.send <- event:
		default:
		}
	}
	h.mu.RUnlock()
	for _, client := range targets {
		time.AfterFunc(50*time.Millisecond, func() {
			_ = client.conn.Close()
		})
	}
}

func (h *Hub) NotifyAndDisconnectServer(serverID string, event Event) {
	h.mu.RLock()
	targets := make([]*Client, 0, len(h.byServer[serverID]))
	event = stamp(event)
	for client := range h.byServer[serverID] {
		targets = append(targets, client)
		select {
		case client.send <- event:
		default:
		}
	}
	h.mu.RUnlock()
	for _, client := range targets {
		client := client
		time.AfterFunc(500*time.Millisecond, func() { _ = client.conn.Close() })
	}
}

func (h *Hub) Publish(event Event) {
	if event.SentAt.IsZero() {
		event.SentAt = time.Now().UTC()
	}
	h.publish <- event
}

// UpdateUserDisplayName updates every active session for a user and informs
// the affected servers so their presence snapshots immediately show the name.
func (h *Hub) UpdateUserDisplayName(userID, displayName string) {
	h.mu.Lock()
	serverIDs := map[string]struct{}{}
	for client := range h.byUser[userID] {
		client.DisplayName = displayName
		if client.ServerID != "" {
			serverIDs[client.ServerID] = struct{}{}
		}
	}
	for serverID := range serverIDs {
		if state, ok := h.voiceState[serverID][userID]; ok {
			state.DisplayName = displayName
			h.voiceState[serverID][userID] = state
		}
	}
	h.mu.Unlock()

	for serverID := range serverIDs {
		h.Publish(Event{
			Type:     "user.profile_updated",
			ServerID: serverID,
			FromUser: userID,
			Payload: map[string]any{
				"user_id": userID, "display_name": displayName,
			},
		})
	}
}

func (h *Hub) SetUserOfflineHandler(handler func(serverID, userID string)) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.userOffline = handler
}

func (h *Hub) SetDirectMessageDeletedHandler(handler func(fileID string)) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.directDeleted = handler
}

func (h *Hub) SetPermissionAuthorizer(authorize func(serverID, userID, permission string) bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.authorize = authorize
}

func (h *Hub) SetEncryptionModeLookup(lookup func(serverID string) (string, bool)) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.encryptionMode = lookup
}

func (h *Hub) DirectDevices(serverID, fromUserID, toUserID string) ([]DirectDevice, bool) {
	h.mu.RLock()
	defer h.mu.RUnlock()
	devices := map[string]DirectDevice{}
	online := map[string]bool{fromUserID: false, toUserID: false}
	for client := range h.byServer[serverID] {
		if _, wanted := online[client.UserID]; !wanted {
			continue
		}
		online[client.UserID] = true
		if client.IdentityPublicKey == "" || client.EnvelopePublicKey == "" {
			return nil, false
		}
		devices[client.DeviceID] = DirectDevice{
			ID: client.DeviceID, UserID: client.UserID,
			IdentityPublicKey: client.IdentityPublicKey,
			EnvelopePublicKey: client.EnvelopePublicKey,
		}
	}
	if !online[fromUserID] || !online[toUserID] {
		return nil, false
	}
	if len(devices) > 64 {
		return nil, false
	}
	result := make([]DirectDevice, 0, len(devices))
	for _, device := range devices {
		result = append(result, device)
	}
	sort.Slice(result, func(i, j int) bool { return result[i].ID < result[j].ID })
	return result, true
}

func (h *Hub) ValidateDirectEnvelopes(serverID, fromUserID, toUserID, senderDeviceID string, envelopes []DirectKeyEnvelope) (string, []string, bool) {
	devices, ok := h.DirectDevices(serverID, fromUserID, toUserID)
	if !ok || len(envelopes) == 0 || len(envelopes) > 64 {
		return "", nil, false
	}
	available := make(map[string]DirectDevice, len(devices))
	for _, device := range devices {
		available[device.ID] = device
	}
	sender, ok := available[senderDeviceID]
	if !ok || sender.UserID != fromUserID {
		return "", nil, false
	}
	seen := make(map[string]bool, len(envelopes))
	hasSender := false
	hasRecipient := false
	recipients := make([]string, 0, len(envelopes))
	for _, envelope := range envelopes {
		device, exists := available[envelope.RecipientDeviceID]
		if !exists || seen[device.ID] || device.UserID != envelope.RecipientUserID ||
			envelope.Algorithm != "openspeak-envelope-v1" || envelope.Ciphertext == "" || len(envelope.Ciphertext) > 65536 {
			return "", nil, false
		}
		seen[device.ID] = true
		hasSender = hasSender || device.ID == senderDeviceID
		hasRecipient = hasRecipient || device.UserID == toUserID
		recipients = append(recipients, device.ID)
	}
	if !hasSender || !hasRecipient {
		return "", nil, false
	}
	return sender.IdentityPublicKey, recipients, true
}

func (h *Hub) add(c *Client) []Event {
	h.mu.Lock()
	defer h.mu.Unlock()
	wasOnlineInServer := h.userOnlineInServerLocked(c.ServerID, c.UserID)
	h.clients[c] = struct{}{}
	addIndexed(h.byUser, c.UserID, c)
	if c.ServerID != "" {
		addIndexed(h.byServer, c.ServerID, c)
	}
	if c.ServerID == "" || wasOnlineInServer {
		return nil
	}
	return []Event{stamp(Event{
		Type:     "user.online",
		ServerID: c.ServerID,
		FromUser: c.UserID,
		Payload: map[string]any{
			"user_id":      c.UserID,
			"display_name": c.DisplayName,
			"device_id":    c.DeviceID,
		},
	})}
}

func (h *Hub) remove(c *Client) []Event {
	h.mu.Lock()
	if _, ok := h.clients[c]; !ok {
		h.mu.Unlock()
		return nil
	}
	delete(h.clients, c)
	removeIndexed(h.byUser, c.UserID, c)
	if c.ServerID != "" {
		removeIndexed(h.byServer, c.ServerID, c)
	}
	close(c.send)
	_ = c.conn.Close()
	if c.ServerID == "" || h.userOnlineInServerLocked(c.ServerID, c.UserID) {
		h.mu.Unlock()
		return nil
	}
	events := []Event{}
	if serverVoice := h.voiceState[c.ServerID]; serverVoice != nil {
		if state, ok := serverVoice[c.UserID]; ok {
			delete(serverVoice, c.UserID)
			events = append(events, stamp(Event{
				Type:      "voice.left",
				ServerID:  c.ServerID,
				ChannelID: state.ChannelID,
				FromUser:  c.UserID,
				Payload: map[string]any{
					"state": state,
				},
			}))
		}
	}
	if serverChannels := h.currentChannel[c.ServerID]; serverChannels != nil {
		if state, ok := serverChannels[c.UserID]; ok {
			delete(serverChannels, c.UserID)
			events = append(events, stamp(Event{
				Type:      "channel.presence_left",
				ServerID:  c.ServerID,
				ChannelID: state.ChannelID,
				FromUser:  c.UserID,
				Payload:   map[string]any{"state": state},
			}))
		}
	}
	for id, message := range h.directMessages {
		if message.ServerID == c.ServerID && message.FromUser == c.UserID {
			delete(h.directMessages, id)
		}
	}
	userOffline := h.userOffline
	h.mu.Unlock()
	if userOffline != nil {
		userOffline(c.ServerID, c.UserID)
	}
	events = append(events, stamp(Event{
		Type:     "user.offline",
		ServerID: c.ServerID,
		FromUser: c.UserID,
		Payload: map[string]any{
			"user_id":      c.UserID,
			"display_name": c.DisplayName,
		},
	}))
	return events
}

func (h *Hub) deliver(event Event) {
	h.mu.RLock()
	defer h.mu.RUnlock()
	var targets map[*Client]struct{}
	switch {
	case event.ToUser != "":
		targets = h.byUser[event.ToUser]
	case event.ServerID != "":
		targets = h.byServer[event.ServerID]
	default:
		targets = h.clients
	}
	for client := range targets {
		select {
		case client.send <- event:
		default:
			slog.Warn("dropping realtime event for slow client", "user_id", client.UserID, "event_type", event.Type)
		}
	}
}

func (h *Hub) closeAll() {
	h.mu.Lock()
	defer h.mu.Unlock()
	for c := range h.clients {
		close(c.send)
		_ = c.conn.Close()
	}
}

func (h *Hub) Snapshot(serverID string) PresenceSnapshot {
	h.mu.RLock()
	defer h.mu.RUnlock()
	byUser := map[string]*UserPresence{}
	for client := range h.byServer[serverID] {
		presence := byUser[client.UserID]
		if presence == nil {
			presence = &UserPresence{
				UserID:      client.UserID,
				DisplayName: client.DisplayName,
				Online:      true,
			}
			byUser[client.UserID] = presence
		}
		presence.Devices = append(presence.Devices, DevicePresence{
			DeviceID:    client.DeviceID,
			ConnectedAt: client.ConnectedAt,
			LastSeenAt:  client.LastSeenAt,
		})
		if client.LastSeenAt.After(presence.LastSeenAt) {
			presence.LastSeenAt = client.LastSeenAt
		}
	}
	users := make([]UserPresence, 0, len(byUser))
	for _, presence := range byUser {
		if state, ok := h.currentChannel[serverID][presence.UserID]; ok {
			channelID := state.ChannelID
			presence.CurrentChannelID = &channelID
		}
		sort.Slice(presence.Devices, func(i, j int) bool {
			return presence.Devices[i].ConnectedAt.Before(presence.Devices[j].ConnectedAt)
		})
		users = append(users, *presence)
	}
	sort.Slice(users, func(i, j int) bool {
		return users[i].UserID < users[j].UserID
	})
	voiceStates := []VoiceState{}
	for _, state := range h.voiceState[serverID] {
		voiceStates = append(voiceStates, state)
	}
	sort.Slice(voiceStates, func(i, j int) bool {
		if voiceStates[i].ChannelID == voiceStates[j].ChannelID {
			return voiceStates[i].UserID < voiceStates[j].UserID
		}
		return voiceStates[i].ChannelID < voiceStates[j].ChannelID
	})
	return PresenceSnapshot{ServerID: serverID, Users: users, VoiceStates: voiceStates}
}

func (h *Hub) CurrentChannel(serverID, userID string) (CurrentChannelState, bool) {
	h.mu.RLock()
	defer h.mu.RUnlock()
	state, ok := h.currentChannel[serverID][userID]
	return state, ok
}

func (h *Hub) SetCurrentChannel(serverID, userID, channelID string) CurrentChannelState {
	h.mu.Lock()
	if h.currentChannel[serverID] == nil {
		h.currentChannel[serverID] = make(map[string]CurrentChannelState)
	}
	old, hadOld := h.currentChannel[serverID][userID]
	state := CurrentChannelState{
		ServerID: serverID, UserID: userID, ChannelID: channelID, UpdatedAt: time.Now().UTC(),
	}
	h.currentChannel[serverID][userID] = state
	h.mu.Unlock()

	if hadOld && old.ChannelID == channelID {
		return state
	}
	if hadOld {
		h.Publish(Event{
			Type: "channel.presence_left", ServerID: serverID, ChannelID: old.ChannelID,
			FromUser: userID, Payload: map[string]any{"state": old},
		})
	}
	h.Publish(Event{
		Type: "channel.presence_joined", ServerID: serverID, ChannelID: channelID,
		FromUser: userID, Payload: map[string]any{"state": state},
	})
	return state
}

func (h *Hub) ClearCurrentChannel(serverID, userID string) (CurrentChannelState, bool) {
	h.mu.Lock()
	serverChannels := h.currentChannel[serverID]
	state, ok := serverChannels[userID]
	if ok {
		delete(serverChannels, userID)
	}
	h.mu.Unlock()
	if ok {
		h.Publish(Event{
			Type: "channel.presence_left", ServerID: serverID, ChannelID: state.ChannelID,
			FromUser: userID, Payload: map[string]any{"state": state},
		})
	}
	return state, ok
}

func (h *Hub) UserOnlineInServer(serverID, userID string) bool {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return h.userOnlineInServerLocked(serverID, userID)
}

// SharedOnlineServer returns a deterministic server where both users currently
// have active WebSocket connections.
func (h *Hub) SharedOnlineServer(fromUserID, toUserID string) (string, bool) {
	h.mu.RLock()
	defer h.mu.RUnlock()
	servers := make([]string, 0)
	seen := make(map[string]struct{})
	for client := range h.byUser[fromUserID] {
		if client.ServerID == "" || !h.userOnlineInServerLocked(client.ServerID, toUserID) {
			continue
		}
		if _, ok := seen[client.ServerID]; !ok {
			seen[client.ServerID] = struct{}{}
			servers = append(servers, client.ServerID)
		}
	}
	if len(servers) == 0 {
		return "", false
	}
	sort.Strings(servers)
	return servers[0], true
}

// SendDirectEvent sends an event to every online device belonging to either
// participant. New messages require both participants to be online.
func (h *Hub) SendDirectEvent(event Event) bool {
	if event.ServerID == "" || event.FromUser == "" || event.ToUser == "" {
		return false
	}
	if event.Type == "direct.message_created" {
		h.mu.RLock()
		modeLookup := h.encryptionMode
		h.mu.RUnlock()
		if modeLookup != nil {
			mode, ok := modeLookup(event.ServerID)
			eventMode, _ := event.Payload["encryption_mode"].(string)
			if eventMode == "" && mode != "e2ee" {
				eventMode = mode
			}
			if !ok || eventMode != mode {
				return false
			}
		}
	}
	event = stamp(event)
	h.mu.Lock()
	defer h.mu.Unlock()
	fromOnline := h.userOnlineInServerLocked(event.ServerID, event.FromUser)
	toOnline := h.userOnlineInServerLocked(event.ServerID, event.ToUser)
	if event.Type == "direct.message_created" && (!fromOnline || !toOnline) {
		return false
	}
	if !fromOnline && !toOnline {
		return false
	}
	if event.Type == "direct.message_created" {
		id, _ := event.Payload["id"].(string)
		fileID, _ := event.Payload["file_id"].(string)
		if id != "" {
			if _, exists := h.directMessages[id]; exists {
				return false
			}
			h.directMessages[id] = directMessageReference{
				ServerID: event.ServerID, FromUser: event.FromUser,
				ToUser: event.ToUser, FileID: fileID,
			}
		}
	}
	targets := map[*Client]struct{}{}
	recipientDeviceIDs, _ := event.Payload["recipient_device_ids"].([]string)
	deviceFilter := make(map[string]bool, len(recipientDeviceIDs))
	for _, deviceID := range recipientDeviceIDs {
		deviceFilter[deviceID] = true
	}
	fromTargeted := false
	toTargeted := false
	for client := range h.byUser[event.FromUser] {
		if client.ServerID == event.ServerID && (len(deviceFilter) == 0 || deviceFilter[client.DeviceID]) {
			targets[client] = struct{}{}
			fromTargeted = true
		}
	}
	for client := range h.byUser[event.ToUser] {
		if client.ServerID == event.ServerID && (len(deviceFilter) == 0 || deviceFilter[client.DeviceID]) {
			targets[client] = struct{}{}
			toTargeted = true
		}
	}
	if event.Type == "direct.message_created" && (!fromTargeted || !toTargeted) {
		id, _ := event.Payload["id"].(string)
		delete(h.directMessages, id)
		return false
	}
	for client := range targets {
		select {
		case client.send <- event:
		default:
			slog.Warn("dropping realtime event for slow client", "user_id", client.UserID, "event_type", event.Type)
		}
	}
	return true
}

func (h *Hub) DeleteDirectMessage(sender *Client, inbound Event) (Event, bool) {
	messageID, _ := inbound.Payload["message_id"].(string)
	if messageID == "" || sender.ServerID == "" {
		return Event{}, false
	}
	h.mu.Lock()
	message, ok := h.directMessages[messageID]
	if !ok || message.ServerID != sender.ServerID || message.FromUser != sender.UserID {
		h.mu.Unlock()
		return Event{}, false
	}
	delete(h.directMessages, messageID)
	directDeleted := h.directDeleted
	h.mu.Unlock()

	if directDeleted != nil && message.FileID != "" {
		directDeleted(message.FileID)
	}
	event := stamp(Event{
		Type: "direct.message_deleted", ServerID: message.ServerID,
		FromUser: message.FromUser, ToUser: message.ToUser,
		Payload: map[string]any{
			"message_id": messageID, "deleted_by_user_id": sender.UserID,
		},
	})
	return event, h.SendDirectEvent(event)
}

func (h *Hub) SetVoiceState(state VoiceState) VoiceState {
	updated, _ := h.setVoiceState(state, false)
	return updated
}

// SetVoiceStateIfScreenAvailable atomically rejects a second screen sharer in
// the same channel. Token checks remain an early error; this is the final
// authority when two publishers race.
func (h *Hub) SetVoiceStateIfScreenAvailable(state VoiceState) (VoiceState, bool) {
	return h.setVoiceState(state, state.ScreenSharing)
}

func (h *Hub) setVoiceState(state VoiceState, requireScreenAvailable bool) (VoiceState, bool) {
	h.mu.Lock()
	if h.voiceState[state.ServerID] == nil {
		h.voiceState[state.ServerID] = make(map[string]VoiceState)
	}
	if requireScreenAvailable {
		for _, current := range h.voiceState[state.ServerID] {
			if current.ChannelID == state.ChannelID && current.ScreenSharing && current.UserID != state.UserID {
				h.mu.Unlock()
				return VoiceState{}, false
			}
		}
	}
	old, hadOld := h.voiceState[state.ServerID][state.UserID]
	state.UpdatedAt = time.Now().UTC()
	h.voiceState[state.ServerID][state.UserID] = state
	h.mu.Unlock()

	eventType := "voice.joined"
	if hadOld {
		eventType = "voice.state_changed"
		if old.ChannelID != state.ChannelID {
			h.Publish(Event{
				Type:      "voice.left",
				ServerID:  state.ServerID,
				ChannelID: old.ChannelID,
				FromUser:  state.UserID,
				Payload:   map[string]any{"state": old},
			})
			eventType = "voice.joined"
		}
	}
	h.Publish(Event{
		Type:      eventType,
		ServerID:  state.ServerID,
		ChannelID: state.ChannelID,
		FromUser:  state.UserID,
		Payload:   map[string]any{"state": state},
	})
	return state, true
}

func (h *Hub) VoiceState(serverID, userID string) (VoiceState, bool) {
	h.mu.RLock()
	defer h.mu.RUnlock()
	state, ok := h.voiceState[serverID][userID]
	return state, ok
}

func (h *Hub) ClearVoiceState(serverID, userID string) (VoiceState, bool) {
	h.mu.Lock()
	serverVoice := h.voiceState[serverID]
	if serverVoice == nil {
		h.mu.Unlock()
		return VoiceState{}, false
	}
	state, ok := serverVoice[userID]
	if ok {
		delete(serverVoice, userID)
	}
	h.mu.Unlock()
	if ok {
		h.Publish(Event{
			Type:      "voice.left",
			ServerID:  serverID,
			ChannelID: state.ChannelID,
			FromUser:  userID,
			Payload:   map[string]any{"state": state},
		})
	}
	return state, ok
}

func (h *Hub) SendDirectMessage(sender *Client, inbound Event) (Event, bool) {
	toUser := inbound.ToUser
	if toUser == "" || sender.ServerID == "" || toUser == sender.UserID {
		return Event{}, false
	}
	body, _ := inbound.Payload["body"].(string)
	kind, _ := inbound.Payload["kind"].(string)
	body = strings.TrimSpace(body)
	if kind == "" {
		kind = "text"
	}
	if kind != "text" || body == "" {
		return Event{}, false
	}
	h.mu.RLock()
	authorize := h.authorize
	modeLookup := h.encryptionMode
	h.mu.RUnlock()
	if authorize != nil && !authorize(sender.ServerID, sender.UserID, "direct.send_text") {
		return Event{}, false
	}
	mode := "none"
	if modeLookup != nil {
		var ok bool
		mode, ok = modeLookup(sender.ServerID)
		if !ok {
			return Event{}, false
		}
	}
	requestedMode, _ := inbound.Payload["encryption_mode"].(string)
	if requestedMode == "" && mode != "e2ee" {
		requestedMode = mode
	}
	if requestedMode != mode {
		return Event{}, false
	}
	messageID := newDirectMessageID()
	payload := map[string]any{
		"id": messageID, "kind": kind, "body": body,
		"encryption_mode": mode,
		"from_user_id":    sender.UserID, "to_user_id": toUser,
	}
	if mode == "e2ee" {
		messageID, _ = inbound.Payload["message_id"].(string)
		nonce, _ := inbound.Payload["nonce"].(string)
		envelopes, ok := directKeyEnvelopes(inbound.Payload["envelopes"])
		bodyBytes, bodyErr := base64.RawURLEncoding.DecodeString(body)
		nonceBytes, nonceErr := base64.RawURLEncoding.DecodeString(nonce)
		if !ValidDirectMessageID(messageID) || bodyErr != nil || len(bodyBytes) < 16 || len(bodyBytes) > 8208 || nonceErr != nil || len(nonceBytes) != 12 || !ok {
			return Event{}, false
		}
		senderIdentity, recipientDeviceIDs, ok := h.ValidateDirectEnvelopes(sender.ServerID, sender.UserID, toUser, sender.DeviceID, envelopes)
		if !ok {
			return Event{}, false
		}
		payload["id"] = messageID
		payload["nonce"] = nonce
		payload["sender_device_id"] = sender.DeviceID
		payload["sender_identity_public_key"] = senderIdentity
		payload["envelopes"] = envelopes
		payload["recipient_device_ids"] = recipientDeviceIDs
	} else if len(body) > 8192 {
		return Event{}, false
	}

	event := stamp(Event{
		Type:     "direct.message_created",
		ServerID: sender.ServerID,
		FromUser: sender.UserID,
		ToUser:   toUser,
		Payload:  payload,
	})

	return event, h.SendDirectEvent(event)
}

func directKeyEnvelopes(value any) ([]DirectKeyEnvelope, bool) {
	raw, err := json.Marshal(value)
	if err != nil {
		return nil, false
	}
	var envelopes []DirectKeyEnvelope
	if err := json.Unmarshal(raw, &envelopes); err != nil {
		return nil, false
	}
	return envelopes, true
}

func ValidDirectMessageID(value string) bool {
	if len(value) != 27 || !strings.HasPrefix(value, "dm_") {
		return false
	}
	_, err := hex.DecodeString(strings.TrimPrefix(value, "dm_"))
	return err == nil
}

func newDirectMessageID() string {
	var b [12]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "dm_" + strconv.FormatInt(time.Now().UnixNano(), 36)
	}
	return "dm_" + hex.EncodeToString(b[:])
}

func (c *Client) readLoop() {
	defer func() {
		c.hub.unregister <- c
	}()
	c.conn.SetReadLimit(1 << 20)
	_ = c.conn.SetReadDeadline(time.Now().Add(75 * time.Second))
	c.conn.SetPongHandler(func(string) error {
		return c.conn.SetReadDeadline(time.Now().Add(75 * time.Second))
	})
	for {
		var event Event
		if err := c.conn.ReadJSON(&event); err != nil {
			return
		}
		switch event.Type {
		case "direct.message_send":
			c.hub.SendDirectMessage(c, event)
		case "direct.message_delete":
			c.hub.DeleteDirectMessage(c, event)
		default:
			// Clients update shared server/channel state through authenticated
			// HTTP APIs. Only explicitly handled WebSocket input events may be
			// rebroadcast, so clients cannot spoof server or channel events.
		}
	}
}

func (c *Client) writeLoop() {
	ticker := time.NewTicker(25 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case event, ok := <-c.send:
			_ = c.conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
			if !ok {
				_ = c.conn.WriteMessage(websocket.CloseMessage, nil)
				return
			}
			if err := c.conn.WriteJSON(event); err != nil {
				return
			}
		case <-ticker.C:
			c.hub.touchPresence(c)
			_ = c.conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
			if err := c.conn.WriteMessage(websocket.PingMessage, nil); err != nil {
				return
			}
		}
	}
}

func (h *Hub) touchPresence(c *Client) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if _, ok := h.clients[c]; !ok {
		return
	}
	c.LastSeenAt = time.Now().UTC()
}

func (h *Hub) userOnlineInServerLocked(serverID, userID string) bool {
	if serverID == "" || userID == "" {
		return false
	}
	for client := range h.byServer[serverID] {
		if client.UserID == userID {
			return true
		}
	}
	return false
}

func stamp(event Event) Event {
	if event.SentAt.IsZero() {
		event.SentAt = time.Now().UTC()
	}
	return event
}

func addIndexed(index map[string]map[*Client]struct{}, key string, c *Client) {
	if key == "" {
		return
	}
	if index[key] == nil {
		index[key] = make(map[*Client]struct{})
	}
	index[key][c] = struct{}{}
}

func removeIndexed(index map[string]map[*Client]struct{}, key string, c *Client) {
	if key == "" {
		return
	}
	delete(index[key], c)
	if len(index[key]) == 0 {
		delete(index, key)
	}
}

func (e Event) String() string {
	b, _ := json.Marshal(e)
	return string(b)
}
