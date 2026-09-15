import React, { useState } from 'react';

const MSPS = [
  { id: 'NCCMSP',        label: 'NCC (Regulator)', pip: 'mno-pip--ncc' },
  { id: 'MTNMSP',        label: 'MTN Nigeria',     pip: 'mno-pip--mtn' },
  { id: 'AIRTELMSP',     label: 'Airtel Nigeria',  pip: 'mno-pip--airtel' },
  { id: 'GLOMSP',        label: 'Globacom',        pip: 'mno-pip--glo' },
  { id: 'NINEMOBILEMSP', label: '9mobile',         pip: 'mno-pip--9mobile' },
];

const ACTIONS = ['READ', 'AUDIT'];

export default function AccessControlView() {
  const [form, setForm] = useState({
    permissionID: 'AIRTELMSP_*_READ',
    grantedTo: 'AIRTELMSP',
    resource: '*',
    action: 'READ',
    grantedBy: 'NCCMSP',
  });
  const [loading, setLoading] = useState(false);
  const [result, setResult] = useState(null);
  const [error, setError] = useState(null);
  const [confirmRevoke, setConfirmRevoke] = useState(false);

  const handleChange = e => {
    const nextForm = { ...form, [e.target.name]: e.target.value };
    if (e.target.name === 'grantedTo' || e.target.name === 'resource' || e.target.name === 'action') {
      nextForm.permissionID = `${nextForm.grantedTo}_${nextForm.resource}_${nextForm.action}`;
    }
    setForm(nextForm);
  };

  const granteeInfo = MSPS.find(m => m.id === form.grantedTo);

  const handleGrant = async e => {
    e.preventDefault();
    setLoading(true);
    setResult(null);
    setError(null);
    setConfirmRevoke(false);

    try {
      const res = await fetch('/api/access/grant', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(form),
      });
      const data = await res.json();
      if (!res.ok) throw new Error(data.error || 'Grant failed');
      setResult({
        type: 'GRANT',
        message: `${form.action} access granted to ${form.grantedTo} for resource "${form.resource}"`,
      });
    } catch (err) {
      setError(err.message);
    } finally {
      setLoading(false);
    }
  };

  const handleRevoke = async () => {
    if (!confirmRevoke) {
      setConfirmRevoke(true);
      return;
    }

    if (!form.permissionID) return;
    setLoading(true);
    setResult(null);
    setError(null);
    setConfirmRevoke(false);

    try {
      const res = await fetch('/api/access/revoke', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ permissionID: form.permissionID }),
      });
      const data = await res.json();
      if (!res.ok) throw new Error(data.error || 'Revoke failed');
      setResult({
        type: 'REVOKE',
        message: `Permission ${form.permissionID} revoked — ${form.grantedTo} can no longer access this resource`,
      });
    } catch (err) {
      setError(err.message);
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="panel">
      <div className="panel-header">
        <h2>Access Control Policy Manager</h2>
        <p>Grant or revoke cross-organisation data access — every action is permanently logged on-chain</p>
      </div>

      <form onSubmit={handleGrant}>
        <div className="form-grid">
          <div className="field-group">
            <div className="field-label"><span>Permission ID</span></div>
            <input
              className="input-control"
              name="permissionID"
              value={form.permissionID}
              onChange={handleChange}
              required
              style={{ fontFamily: 'var(--font-mono)' }}
            />
          </div>

          <div className="field-group">
            <div className="field-label"><span>Grantee Organisation</span></div>
            <select className="input-control" name="grantedTo" value={form.grantedTo} onChange={handleChange}>
              {MSPS.map(m => (
                <option key={m.id} value={m.id}>{m.label} ({m.id})</option>
              ))}
            </select>
          </div>

          <div className="field-group">
            <div className="field-label"><span>Action Scope</span></div>
            <select className="input-control" name="action" value={form.action} onChange={handleChange}>
              {ACTIONS.map(a => (
                <option key={a} value={a}>{a}</option>
              ))}
            </select>
          </div>

          <div className="field-group">
            <div className="field-label"><span>Target Resource</span></div>
            <input
              className="input-control"
              name="resource"
              value={form.resource}
              onChange={handleChange}
              placeholder="* for all, or a specific subscriber ID"
              required
              style={{ fontFamily: 'var(--font-mono)' }}
            />
          </div>
        </div>

        {/* Grant + Revoke buttons */}
        <div style={{ display: 'flex', gap: '12px', alignItems: 'center', marginTop: '12px' }}>
          <button type="submit" className="btn-primary" disabled={loading}>
            {loading ? 'Submitting policy…' : (
              <>
                {granteeInfo && <span className={`mno-pip ${granteeInfo.pip}`} />}
                <span>Grant Access</span>
              </>
            )}
          </button>

          <div style={{ width: '1px', height: '28px', background: 'var(--rule-light)' }} />

          <button
            type="button"
            className="btn-danger"
            onClick={handleRevoke}
            disabled={loading}
          >
            {confirmRevoke ? 'Confirm — this is permanent' : 'Revoke Access'}
          </button>

          {confirmRevoke && (
            <button
              type="button"
              className="btn-secondary"
              onClick={() => setConfirmRevoke(false)}
              style={{ fontSize: '0.82rem', padding: '8px 16px' }}
            >
              Cancel
            </button>
          )}
        </div>
      </form>

      {/* Result */}
      {result && (
        <div className="output-card" style={
          result.type === 'REVOKE'
            ? { borderLeftColor: 'var(--caution)' }
            : {}
        }>
          <div className="output-header">
            <div className="output-title" style={
              result.type === 'REVOKE'
                ? { color: 'var(--caution)' }
                : {}
            }>
              <span>{result.type === 'GRANT' ? '✓' : '⊘'}</span>
              <span>{result.message}</span>
            </div>
            <span className={`badge ${result.type === 'GRANT' ? 'badge-active' : 'badge-deactivated'}`}>
              {result.type}
            </span>
          </div>
        </div>
      )}

      {/* Error */}
      {error && (
        <div className="output-card output-card--error">
          <div style={{ color: 'var(--caution)', fontWeight: 600, fontSize: '0.88rem' }}>
            Policy operation failed — {error}
          </div>
          <div style={{ color: 'var(--muted)', fontSize: '0.82rem', marginTop: '6px' }}>
            Verify the permission ID and target organisation, then retry.
          </div>
        </div>
      )}
    </div>
  );
}
