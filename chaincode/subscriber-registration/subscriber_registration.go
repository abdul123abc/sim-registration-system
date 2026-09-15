// Package main implements the Subscriber Registration chaincode.
// Chapter Three, Section 3.3 — Contract 1.
// Ledger is APPEND-ONLY: no delete function is exposed. Deactivation is
// handled as a new state-transition entry (DeactivateSubscriber).
package main

import (
	"encoding/json"
	"fmt"
	"time"

	"github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// MaxRegistrationsPerOperator is the maximum number of ACTIVE registrations
// permitted for a single identity commitment under one operator (MNO).
// Section 3.2.3: the duplicate-detection rule is scoped per identity per
// operator, not globally across the network. Adjust this constant to change
// the configured limit without hunting through the function body.
const MaxRegistrationsPerOperator = 4

// SubscriberRegistrationContract implements the Fabric SmartContract interface.
type SubscriberRegistrationContract struct {
	contractapi.Contract
}

// SubscriberRecord is the on-chain representation of a registered subscriber.
// Raw NIN is NEVER stored — only the identity commitment (hash) and IPFS CID
// of the AES-256 encrypted payload. See Chapter Three, Section 3.2.
type SubscriberRecord struct {
	SubscriberID   string `json:"subscriberID"`   // unique key (MNO-assigned)
	MSIDN          string `json:"msisdn"`         // phone number
	MNO            string `json:"mno"`            // originating MNO
	IdentityCommit string `json:"identityCommit"` // SHA-256 commitment of NIN+fingerprint
	IPFSHash       string `json:"ipfsHash"`       // CID of encrypted off-chain payload
	Status         string `json:"status"`         // "ACTIVE" | "DEACTIVATED"
	RegisteredAt   string `json:"registeredAt"`   // RFC3339 timestamp
	LastUpdatedAt  string `json:"lastUpdatedAt"`  // RFC3339 timestamp
}

// countActiveRegistrations queries the ledger for ACTIVE SubscriberRecord
// entries where both IdentityCommit and MNO match the supplied values.
func countActiveRegistrations(
	ctx contractapi.TransactionContextInterface,
	identityCommit string,
	mno string,
) (int, error) {
	queryStr := fmt.Sprintf(
		`{"selector":{"identityCommit":%q,"mno":%q,"status":"ACTIVE"}}`,
		identityCommit, mno,
	)

	iter, err := ctx.GetStub().GetQueryResult(queryStr)
	if err != nil {
		return 0, fmt.Errorf("active-registration count query failed: %w", err)
	}
	defer iter.Close()

	count := 0
	for iter.HasNext() {
		if _, err := iter.Next(); err != nil {
			return 0, fmt.Errorf("iterator error during registration count: %w", err)
		}
		count++
	}
	return count, nil
}

// isMSISDNActive checks if an ACTIVE SubscriberRecord already exists for this mobile number (MSISDN).
func isMSISDNActive(
	ctx contractapi.TransactionContextInterface,
	msisdn string,
) (bool, error) {
	queryStr := fmt.Sprintf(
		`{"selector":{"msisdn":%q,"status":"ACTIVE"}}`,
		msisdn,
	)

	iter, err := ctx.GetStub().GetQueryResult(queryStr)
	if err != nil {
		return false, fmt.Errorf("msisdn query failed: %w", err)
	}
	defer iter.Close()

	return iter.HasNext(), nil
}

// RegisterSubscriber commits a new subscriber record to the ledger.
func (c *SubscriberRegistrationContract) RegisterSubscriber(
	ctx contractapi.TransactionContextInterface,
	subscriberID string,
	msisdn string,
	mno string,
	identityCommit string,
	ipfsHash string,
) error {
	// ── 1. Validate required inputs. ────────────────────────────────────────
	if subscriberID == "" || msisdn == "" || mno == "" || identityCommit == "" || ipfsHash == "" {
		return fmt.Errorf("all fields (subscriberID, msisdn, mno, identityCommit, ipfsHash) are required")
	}

	// ── 2. MSISDN (phone number) uniqueness guard. ───────────────────────────
	msisdnInUse, err := isMSISDNActive(ctx, msisdn)
	if err != nil {
		return fmt.Errorf("msisdn uniqueness check failed: %w", err)
	}
	if msisdnInUse {
		return fmt.Errorf("DUPLICATE_MSISDN: phone number %s is already registered to an active SIM on the network", msisdn)
	}

	// ── 3. Per-identity-per-operator limit check (Section 3.2.3). ──────────
	activeCount, err := countActiveRegistrations(ctx, identityCommit, mno)
	if err != nil {
		return fmt.Errorf("REGISTRATION_LIMIT_EXCEEDED check failed: %w", err)
	}
	if activeCount >= MaxRegistrationsPerOperator {
		return fmt.Errorf(
			"REGISTRATION_LIMIT_EXCEEDED: identity commitment %s already has %d active registration(s) under operator %s (limit: %d)",
			identityCommit, activeCount, mno, MaxRegistrationsPerOperator,
		)
	}

	// ── 4. SubscriberID uniqueness guard. ────────────────────────────────────
	exists, err := c.Exists(ctx, subscriberID)
	if err != nil {
		return fmt.Errorf("existence check failed: %w", err)
	}
	if exists {
		return fmt.Errorf("subscriber %s already exists — duplicate subscriberID rejected", subscriberID)
	}

	// ── 5. Build and persist the record. ────────────────────────────────────
	txTime, err := ctx.GetStub().GetTxTimestamp()
	var now string
	if err == nil && txTime != nil {
		now = time.Unix(txTime.Seconds, int64(txTime.Nanos)).UTC().Format(time.RFC3339)
	} else {
		now = time.Now().UTC().Format(time.RFC3339)
	}
	record := SubscriberRecord{
		SubscriberID:   subscriberID,
		MSIDN:          msisdn,
		MNO:            mno,
		IdentityCommit: identityCommit,
		IPFSHash:       ipfsHash,
		Status:         "ACTIVE",
		RegisteredAt:   now,
		LastUpdatedAt:  now,
	}

	data, err := json.Marshal(record)
	if err != nil {
		return fmt.Errorf("failed to serialise subscriber record: %w", err)
	}

	return ctx.GetStub().PutState(subscriberID, data)
}

// GetSubscriber retrieves a subscriber record by ID.
func (c *SubscriberRegistrationContract) GetSubscriber(
	ctx contractapi.TransactionContextInterface,
	subscriberID string,
) (*SubscriberRecord, error) {
	if subscriberID == "" {
		return nil, fmt.Errorf("subscriberID is required")
	}

	data, err := ctx.GetStub().GetState(subscriberID)
	if err != nil {
		return nil, fmt.Errorf("ledger read failed: %w", err)
	}
	if data == nil {
		return nil, fmt.Errorf("subscriber %s not found", subscriberID)
	}

	var record SubscriberRecord
	if err := json.Unmarshal(data, &record); err != nil {
		return nil, fmt.Errorf("failed to deserialise record: %w", err)
	}
	return &record, nil
}

// QuerySubscribers performs a CouchDB selector rich query.
func (c *SubscriberRegistrationContract) QuerySubscribers(
	ctx contractapi.TransactionContextInterface,
	queryString string,
) ([]*SubscriberRecord, error) {
	if queryString == "" {
		return nil, fmt.Errorf("queryString is required")
	}

	iter, err := ctx.GetStub().GetQueryResult(queryString)
	if err != nil {
		return nil, fmt.Errorf("query failed: %w", err)
	}
	defer iter.Close()

	var results []*SubscriberRecord
	for iter.HasNext() {
		kv, err := iter.Next()
		if err != nil {
			return nil, fmt.Errorf("iterator error: %w", err)
		}
		var record SubscriberRecord
		if err := json.Unmarshal(kv.Value, &record); err != nil {
			return nil, fmt.Errorf("deserialise error: %w", err)
		}
		results = append(results, &record)
	}
	return results, nil
}

// Exists returns true if a subscriber record with the given ID is present on the ledger.
func (c *SubscriberRegistrationContract) Exists(
	ctx contractapi.TransactionContextInterface,
	subscriberID string,
) (bool, error) {
	data, err := ctx.GetStub().GetState(subscriberID)
	if err != nil {
		return false, fmt.Errorf("ledger read failed: %w", err)
	}
	return data != nil, nil
}

// DeactivateSubscriber appends a deactivation state-transition to the ledger.
func (c *SubscriberRegistrationContract) DeactivateSubscriber(
	ctx contractapi.TransactionContextInterface,
	subscriberID string,
) error {
	record, err := c.GetSubscriber(ctx, subscriberID)
	if err != nil {
		return err
	}
	if record.Status == "DEACTIVATED" {
		return fmt.Errorf("subscriber %s is already deactivated", subscriberID)
	}

	txTime, err := ctx.GetStub().GetTxTimestamp()
	var now string
	if err == nil && txTime != nil {
		now = time.Unix(txTime.Seconds, int64(txTime.Nanos)).UTC().Format(time.RFC3339)
	} else {
		now = time.Now().UTC().Format(time.RFC3339)
	}
	record.Status = "DEACTIVATED"
	record.LastUpdatedAt = now

	data, err := json.Marshal(record)
	if err != nil {
		return fmt.Errorf("failed to serialise updated record: %w", err)
	}
	return ctx.GetStub().PutState(subscriberID, data)
}
