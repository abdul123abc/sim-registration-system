// Package main implements the Update Tracking chaincode.
// Chapter Three, Section 3.3 — Contract 3.
// This contract is the system's immutable audit trail.
// It is APPEND-ONLY by design — no update or delete function is exposed.
// Every event appended here is the record that Chapter One argues is missing
// from the current centralised NCC system.
package main

import (
	"encoding/json"
	"fmt"
	"time"

	"github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// UpdateTrackingContract implements the Fabric SmartContract interface.
type UpdateTrackingContract struct {
	contractapi.Contract
}

// AuditEvent represents a single immutable event in the audit trail.
type AuditEvent struct {
	EventID      string `json:"eventID"`      // unique event key
	SubscriberID string `json:"subscriberID"` // related subscriber
	EventType    string `json:"eventType"`    // e.g. "REGISTERED", "DEACTIVATED", "PROOF_VERIFIED"
	MNO          string `json:"mno"`          // originating MNO
	Timestamp    string `json:"timestamp"`    // RFC3339
	Details      string `json:"details"`      // freeform detail string
}

// LogEvent appends a new audit event to the ledger.
// The key is composite: EventID must be globally unique (caller-generated).
// Chapter Three, Section 3.3.
func (c *UpdateTrackingContract) LogEvent(
	ctx contractapi.TransactionContextInterface,
	eventID string,
	subscriberID string,
	eventType string,
	mno string,
	details string,
) error {
	if eventID == "" || subscriberID == "" || eventType == "" || mno == "" {
		return fmt.Errorf("eventID, subscriberID, eventType, and mno are all required")
	}

	// Prevent overwriting an existing event — append-only guarantee.
	existing, err := ctx.GetStub().GetState(eventID)
	if err != nil {
		return fmt.Errorf("ledger read failed: %w", err)
	}
	if existing != nil {
		return fmt.Errorf("eventID %s already exists — event log is append-only", eventID)
	}

	txTime, err := ctx.GetStub().GetTxTimestamp()
	var now string
	if err == nil && txTime != nil {
		now = time.Unix(txTime.Seconds, int64(txTime.Nanos)).UTC().Format(time.RFC3339)
	} else {
		now = time.Now().UTC().Format(time.RFC3339)
	}
	event := AuditEvent{
		EventID:      eventID,
		SubscriberID: subscriberID,
		EventType:    eventType,
		MNO:          mno,
		Timestamp:    now,
		Details:      details,
	}
	data, err := json.Marshal(event)
	if err != nil {
		return fmt.Errorf("failed to serialise audit event: %w", err)
	}
	return ctx.GetStub().PutState(eventID, data)
}

// GetHistory returns the full Fabric key-level history for a given subscriber.
// This leverages Fabric's built-in GetHistoryForKey API, which returns every
// version of the state keyed by subscriberID across all committed blocks.
// Chapter Three, Section 3.3.
func (c *UpdateTrackingContract) GetHistory(
	ctx contractapi.TransactionContextInterface,
	subscriberID string,
) (string, error) {
	if subscriberID == "" {
		return "", fmt.Errorf("subscriberID is required")
	}

	iter, err := ctx.GetStub().GetHistoryForKey(subscriberID)
	if err != nil {
		return "", fmt.Errorf("GetHistoryForKey failed: %w", err)
	}
	defer iter.Close()

	type HistoryEntry struct {
		TxID      string          `json:"txID"`
		Timestamp string          `json:"timestamp"`
		IsDelete  bool            `json:"isDelete"`
		Value     json.RawMessage `json:"value"`
	}

	var entries []HistoryEntry
	for iter.HasNext() {
		mod, err := iter.Next()
		if err != nil {
			return "", fmt.Errorf("iterator error: %w", err)
		}
		entries = append(entries, HistoryEntry{
			TxID:      mod.TxId,
			Timestamp: time.Unix(mod.Timestamp.Seconds, int64(mod.Timestamp.Nanos)).UTC().Format(time.RFC3339),
			IsDelete:  mod.IsDelete,
			Value:     mod.Value,
		})
	}

	out, err := json.Marshal(entries)
	if err != nil {
		return "", fmt.Errorf("serialise error: %w", err)
	}
	return string(out), nil
}

// GetAuditTrail returns all AuditEvent records for a given subscriberID using
// a CouchDB rich query. Chapter Three, Section 3.3.
func (c *UpdateTrackingContract) GetAuditTrail(
	ctx contractapi.TransactionContextInterface,
	subscriberID string,
) ([]*AuditEvent, error) {
	if subscriberID == "" {
		return nil, fmt.Errorf("subscriberID is required")
	}

	query := fmt.Sprintf(`{"selector":{"subscriberID":"%s"}}`, subscriberID)
	iter, err := ctx.GetStub().GetQueryResult(query)
	if err != nil {
		return nil, fmt.Errorf("query failed: %w", err)
	}
	defer iter.Close()

	var events []*AuditEvent
	for iter.HasNext() {
		kv, err := iter.Next()
		if err != nil {
			return nil, fmt.Errorf("iterator error: %w", err)
		}
		var ev AuditEvent
		if err := json.Unmarshal(kv.Value, &ev); err != nil {
			return nil, fmt.Errorf("deserialise error: %w", err)
		}
		events = append(events, &ev)
	}
	return events, nil
}

func main() {
	cc, err := contractapi.NewChaincode(&UpdateTrackingContract{})
	if err != nil {
		panic("Error creating UpdateTrackingContract: " + err.Error())
	}
	if err := cc.Start(); err != nil {
		panic("Error starting UpdateTrackingContract: " + err.Error())
	}
}
