import React, { useState } from 'react';

const MSPS = [
  { id: 'MTNMSP',        label: 'MTN Nigeria',  pip: 'mno-pip--mtn' },
  { id: 'AIRTELMSP',     label: 'Airtel',       pip: 'mno-pip--airtel' },
  { id: 'GLOMSP',        label: 'Globacom',     pip: 'mno-pip--glo' },
  { id: 'NINEMOBILEMSP', label: '9mobile',      pip: 'mno-pip--9mobile' },
  { id: 'NCCMSP',        label: 'NCC',          pip: 'mno-pip--ncc' },
];

export default function MNORecordView() {
  const [callerMSPID, setCallerMSPID] = useState('MTNMSP');
  const [subscriberID, setSubscriberID] = useState('');
  const [record, setRecord] = useState(null);
  const [error, setError] = useState(null);
  const [loading, setLoading] = useState(false);
  const [updating, setUpdating] = useState(false);
  const [updateMsg, setUpdateMsg] = useState(null);
  const [copiedKey, setCopiedKey] = useState('');

  const copyToClipboard = (text, key) => {
    if (!text) return;
    navigator.clipboard.writeText(text);
    setCopiedKey(key);
    setTimeout(() => setCopiedKey(''), 2000);
  };

  const truncate = (str) => {
    if (!str || str.length <= 16) return str;
    return str.slice(0, 8) + '…' + str.slice(-8);
  };

  const handleLookup = async e => {
    if (e) e.preventDefault();
    setLoading(true);
    setRecord(null);
    setError(null);
    setUpdateMsg(null);

    try {
      const res = await fetch(
        `/api/access/read/${encodeURIComponent(callerMSPID)}/${encodeURIComponent(subscriberID.trim())}`
      );
      const data = await res.json();
      if (!res.ok) throw new Error(data.error || 'Lookup failed');
      setRecord(data);
    } catch (err) {
      setError(err.message);
    } finally {
      setLoading(false);
    }
  };

  const handleDeactivate = async () => {
    if (!record || !record.subscriberID) return;
    setUpdating(true);
    setUpdateMsg(null);

    try {
      const res = await fetch('/api/registration/deactivate', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ subscriberID: record.subscriberID }),
      });
      const data = await res.json();
      if (!res.ok) throw new Error(data.error || 'Deactivation failed');
      setUpdateMsg('✓ Status updated to DEACTIVATED on-chain (Append-Only Event logged)');
      // Refresh record from ledger
      handleLookup(null);
    } catch (err) {
      setError(err.message);
    } finally {
      setUpdating(false);
    }
  };

  const callerInfo = MSPS.find(m => m.id === callerMSPID);

  return (
    <div className="panel">
      <div className="panel-header">
        <h2>Subscriber Record Lookup & Status Management</h2>
        <p>Query the ledger via access-control policy check — only authorised organisations may read</p>
      </div>

      <form onSubmit={handleLookup}>
        <div className="form-grid">
          <div className="field-group">
            <div className="field-label">
              <span>Requesting Organisation</span>
            </div>
            <select
              className="input-control"
              value={callerMSPID}
              onChange={e => setCallerMSPID(e.target.value)}
            >
              {MSPS.map(m => (
                <option key={m.id} value={m.id}>{m.label} ({m.id})</option>
              ))}
            </select>
          </div>

          <div className="field-group">
            <div className="field-label">
              <span>Subscriber ID</span>
            </div>
            <input
              className="input-control"
              value={subscriberID}
              onChange={e => setSubscriberID(e.target.value)}
              placeholder="Paste subscriber ID from registration"
              required
              style={{ fontFamily: 'var(--font-mono)' }}
            />
          </div>
        </div>

        <button type="submit" className="btn-primary" disabled={loading}>
          {loading ? (
            <>
              <div className="spinner" />
              <span>Checking access policies…</span>
            </>
          ) : (
            <>
              {callerInfo && <span className={`mno-pip ${callerInfo.pip}`} />}
              <span>Look Up Record</span>
            </>
          )}
        </button>
      </form>

      {updateMsg && (
        <div className="output-card" style={{ borderLeftColor: 'var(--seal)' }}>
          <div style={{ color: 'var(--seal)', fontWeight: 600, fontSize: '0.88rem' }}>
            {updateMsg}
          </div>
        </div>
      )}

      {record && (
        <div className="output-card">
          <div className="output-header">
            <div style={{ display: 'flex', alignItems: 'center', gap: '10px' }}>
              <span style={{ fontSize: '0.95rem', fontWeight: 700, color: 'var(--ink)' }}>
                Subscriber Record
              </span>
              <span className="badge badge-mno">{record.mno}</span>
            </div>
            <span
              className={`badge ${
                record.status === 'ACTIVE' ? 'badge-active' : 'badge-deactivated'
              }`}
            >
              {record.status || 'ACTIVE'}
            </span>
          </div>

          <div className="table-container">
            <table className="data-table">
              <tbody>
                {[
                  { key: 'subID', label: 'Subscriber ID', value: record.subscriberID, mono: true, copyable: true },
                  { key: 'msisdn', label: 'Phone Number (MSISDN)', value: record.msisdn, copyable: true },
                  { key: 'mno', label: 'Originating MNO', value: record.mno },
                  { key: 'commit', label: 'Identity Commitment', value: record.identityCommit, mono: true, long: true, copyable: true },
                  { key: 'ipfs', label: 'Encrypted IPFS CID', value: record.ipfsHash, mono: true, long: true, copyable: true },
                  { key: 'reg', label: 'Registered', value: record.registeredAt, mono: true },
                  { key: 'updated', label: 'Last Updated', value: record.lastUpdatedAt, mono: true },
                ].map(row => (
                  <tr key={row.label}>
                    <th style={{ width: '220px' }}>{row.label}</th>
                    <td>
                      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: '12px' }}>
                        {row.mono ? (
                          <span
                            className="mono-field"
                            style={{ display: 'inline-block' }}
                            title={row.value}
                          >
                            {row.long ? truncate(row.value) : row.value}
                          </span>
                        ) : (
                          <strong style={{ color: 'var(--ink)' }}>{row.value}</strong>
                        )}

                        {row.copyable && (
                          <button
                            type="button"
                            className="btn-secondary"
                            onClick={() => copyToClipboard(row.value, row.key)}
                            style={{ fontSize: '0.72rem', padding: '3px 8px', lineHeight: 1 }}
                            title={`Copy ${row.label}`}
                          >
                            {copiedKey === row.key ? '✓ Copied' : '📋 Copy'}
                          </button>
                        )}
                      </div>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          {record.status === 'ACTIVE' && (
            <div style={{ marginTop: '16px', paddingTop: '16px', borderTop: '1px solid var(--rule-light)' }}>
              <button
                type="button"
                className="btn-danger"
                onClick={handleDeactivate}
                disabled={updating}
                style={{ fontSize: '0.82rem' }}
              >
                {updating ? 'Updating state on-chain…' : '🔴 Deactivate Subscriber SIM (Append-Only Update)'}
              </button>
            </div>
          )}
        </div>
      )}

      {error && (
        <div className="output-card output-card--error">
          <div style={{ color: 'var(--caution)', fontWeight: 600, fontSize: '0.88rem' }}>
            Access denied for {callerMSPID} — {error}
          </div>
          <div style={{ color: 'var(--muted)', fontSize: '0.82rem', marginTop: '6px' }}>
            Verify that {callerMSPID} has been granted READ permission for this subscriber.
          </div>
        </div>
      )}
    </div>
  );
}
