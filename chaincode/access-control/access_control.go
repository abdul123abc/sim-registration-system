// Package main implements the Access Control chaincode.
// Chapter Three, Section 3.3 — Contract 4.
// Controls which organisations/roles can read subscriber records cross-MNO.
// Endorsement policy for permission changes: simple majority of MNO peers.
// Chapter Three, Section 3.4.2.
package main

import (
	"encoding/json"
	"fmt"
	"time"

	"github.com/hyperledger/fabric-contract-api-go/contractapi"
)

// AccessControlContract implements the Fabric SmartContract interface.
type AccessControlContract struct {
	contractapi.Contract
}

// PermissionRecord represents an access-control grant on the ledger.
type PermissionRecord struct {
	PermissionID string `json:"permissionID"` // unique key
	GrantedTo    string `json:"grantedTo"`    // MSPID of the grantee (e.g. "MTNMSP")
	Resource     string `json:"resource"`     // subscriberID or "*" for wildcard
	Action       string `json:"action"`       // "READ" | "AUDIT"
	GrantedBy    string `json:"grantedBy"`    // MSPID of the granting org (NCC)
	Active       bool   `json:"active"`
	GrantedAt    string `json:"grantedAt"`
	UpdatedAt    string `json:"updatedAt"`
}

// permKey returns the ledger key for a permission record.
func permKey(permissionID string) string {
	return "PERM_" + permissionID
}

// CheckPermission returns true if grantedTo has an active permission for
// the given resource and action. Chapter Three, Section 3.3.
func (c *AccessControlContract) CheckPermission(
	ctx contractapi.TransactionContextInterface,
	permissionID string,
) (bool, error) {
	if permissionID == "" {
		return false, fmt.Errorf("permissionID is required")
	}
	data, err := ctx.GetStub().GetState(permKey(permissionID))
	if err != nil {
		return false, fmt.Errorf("ledger read failed: %w", err)
	}
	if data == nil {
		return false, nil
	}
	var rec PermissionRecord
	if err := json.Unmarshal(data, &rec); err != nil {
		return false, fmt.Errorf("deserialise error: %w", err)
	}
	return rec.Active, nil
}

// GrantPermission creates a new access-control grant.
// Endorsement policy (Chapter Three, Section 3.4.2): simple majority of MNO peers.
// This is enforced at the channel policy level in configtx.yaml — this function
// only records the grant; the network rejects the transaction if policy is unmet.
func (c *AccessControlContract) GrantPermission(
	ctx contractapi.TransactionContextInterface,
	permissionID string,
	grantedTo string,
	resource string,
	action string,
	grantedBy string,
) error {
	if permissionID == "" || grantedTo == "" || resource == "" || action == "" || grantedBy == "" {
		return fmt.Errorf("all fields are required")
	}
	// Prevent overwrite of an existing active grant.
	existing, _ := ctx.GetStub().GetState(permKey(permissionID))
	if existing != nil {
		return fmt.Errorf("permissionID %s already exists — use RevokePermission first if re-granting", permissionID)
	}

	txTime, err := ctx.GetStub().GetTxTimestamp()
	var now string
	if err == nil && txTime != nil {
		now = time.Unix(txTime.Seconds, int64(txTime.Nanos)).UTC().Format(time.RFC3339)
	} else {
		now = time.Now().UTC().Format(time.RFC3339)
	}
	rec := PermissionRecord{
		PermissionID: permissionID,
		GrantedTo:    grantedTo,
		Resource:     resource,
		Action:       action,
		GrantedBy:    grantedBy,
		Active:       true,
		GrantedAt:    now,
		UpdatedAt:    now,
	}
	data, err := json.Marshal(rec)
	if err != nil {
		return fmt.Errorf("serialise error: %w", err)
	}
	return ctx.GetStub().PutState(permKey(permissionID), data)
}

// RevokePermission sets a permission record to inactive (append-only — the
// record remains on the ledger for audit purposes).
func (c *AccessControlContract) RevokePermission(
	ctx contractapi.TransactionContextInterface,
	permissionID string,
) error {
	if permissionID == "" {
		return fmt.Errorf("permissionID is required")
	}
	data, err := ctx.GetStub().GetState(permKey(permissionID))
	if err != nil {
		return fmt.Errorf("ledger read failed: %w", err)
	}
	if data == nil {
		return fmt.Errorf("permissionID %s not found", permissionID)
	}
	var rec PermissionRecord
	if err := json.Unmarshal(data, &rec); err != nil {
		return fmt.Errorf("deserialise error: %w", err)
	}
	if !rec.Active {
		return fmt.Errorf("permissionID %s is already revoked", permissionID)
	}
	rec.Active = false
	rec.UpdatedAt = time.Now().UTC().Format(time.RFC3339)
	updated, err := json.Marshal(rec)
	if err != nil {
		return fmt.Errorf("serialise error: %w", err)
	}
	return ctx.GetStub().PutState(permKey(permissionID), updated)
}

// ReadSubscriber is the access-controlled read gateway for cross-operator
// subscriber lookups. The caller's MSPID is checked against the ledger before
// data is returned. In this prototype the backend enforces this by invoking
// CheckPermission before calling GetSubscriber — this function provides an
// additional on-chain guard.
// Chapter Three, Section 3.3.
func (c *AccessControlContract) ReadSubscriber(
	ctx contractapi.TransactionContextInterface,
	callerMSPID string,
	subscriberID string,
) (string, error) {
	if callerMSPID == "" || subscriberID == "" {
		return "", fmt.Errorf("callerMSPID and subscriberID are required")
	}
	// Check for an active READ permission for this caller + resource.
	permID := callerMSPID + "_" + subscriberID + "_READ"
	active, err := c.CheckPermission(ctx, permID)
	if err != nil {
		return "", err
	}
	if !active {
		// Also check for a wildcard grant.
		wildcardPermID := callerMSPID + "_*_READ"
		active, err = c.CheckPermission(ctx, wildcardPermID)
		if err != nil {
			return "", err
		}
	}
	if !active {
		return "", fmt.Errorf("access denied: %s does not have READ permission for subscriber %s", callerMSPID, subscriberID)
	}

	// Read subscriber data from the Subscriber Registration contract state.
	// Both contracts share the same channel so GetState is cross-contract safe
	// only for keys written by this peer — in practice the backend calls the
	// Subscriber Registration contract directly after permission is confirmed.
	// DESIGN ASSUMPTION: ReadSubscriber delegates the actual data fetch to the
	// backend layer; on-chain it only validates permission and returns "GRANTED".
	return "GRANTED", nil
}

func main() {
	cc, err := contractapi.NewChaincode(&AccessControlContract{})
	if err != nil {
		panic("Error creating AccessControlContract: " + err.Error())
	}
	if err := cc.Start(); err != nil {
		panic("Error starting AccessControlContract: " + err.Error())
	}
}
