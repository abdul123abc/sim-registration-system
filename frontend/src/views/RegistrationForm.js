import React, { useState } from 'react';

const MNOS = [
  { id: 'MTN',        name: 'MTN Nigeria',     msp: 'MTNMSP',        pip: 'mno-pip--mtn' },
  { id: 'Airtel',     name: 'Airtel Nigeria',  msp: 'AIRTELMSP',     pip: 'mno-pip--airtel' },
  { id: 'Glo',        name: 'Globacom (Glo)',  msp: 'GLOMSP',        pip: 'mno-pip--glo' },
  { id: 'NineMobile', name: '9mobile',         msp: 'NINEMOBILEMSP', pip: 'mno-pip--9mobile' },
];

const STEPS = [
  'Computing Poseidon identity commitment (NIN + biometrics)',
  'Generating Groth16 zk-SNARK proof via snarkjs',
  'Encrypting payload (AES-256-GCM) and pinning to IPFS',
  'Submitting transaction to Fabric consensus peers',
];

const randomHex = byteCount => {
  const bytes = new Uint8Array(byteCount);
  window.crypto.getRandomValues(bytes);
  return Array.from(bytes, byte => byte.toString(16).padStart(2, '0')).join('');
};

export default function RegistrationForm() {
  const [form, setForm] = useState({
    nin: '12345678901',
    fingerprintHash: randomHex(32),
    msisdn: '08011223344',
    mno: 'MTN',
  });
  const [loading, setLoading] = useState(false);
  const [stepProgress, setStepProgress] = useState(0);
  const [result, setResult] = useState(null);
  const [error, setError] = useState(null);
  const [copiedField, setCopiedField] = useState(null);

  const handleChange = e => setForm({ ...form, [e.target.name]: e.target.value });

  const fillDemo = () => {
    const randomNIN = Math.floor(10000000000 + Math.random() * 90000000000).toString();
    const randomFp = randomHex(32);
    const randomPhone = '080' + Math.floor(10000000 + Math.random() * 90000000).toString();
    setForm({
      nin: randomNIN,
      fingerprintHash: randomFp,
      msisdn: randomPhone,
      mno: MNOS[Math.floor(Math.random() * MNOS.length)].id,
    });
  };

  const copyToClipboard = (text, fieldName) => {
    navigator.clipboard.writeText(text);
    setCopiedField(fieldName);
    setTimeout(() => setCopiedField(null), 2000);
  };

  const truncate = (str) => {
    if (!str || str.length <= 16) return str;
    return str.slice(0, 8) + '…' + str.slice(-8);
  };

  const handleSubmit = async e => {
    e.preventDefault();
    setLoading(true);
    setResult(null);
    setError(null);
    setStepProgress(1);

    try {
      setTimeout(() => setStepProgress(2), 300);
      setTimeout(() => setStepProgress(3), 700);

      const res = await fetch('/api/registration/register', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(form),
      });
      const data = await res.json();
      if (!res.ok) throw new Error(data.error || 'Registration failed');

      setStepProgress(4);
      setResult(data);
    } catch (err) {
      setError(err.message);
    } finally {
      setLoading(false);
    }
  };

  const selectedMNO = MNOS.find(m => m.id === form.mno);

  return (
    <div className="panel">
      <div className="panel-header">
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
          <div>
            <h2>Subscriber Registration</h2>
            <p>ZK identity commitment, encrypted IPFS payload, and ledger commit</p>
          </div>
          <button type="button" className="preset-btn" onClick={fillDemo}>
            Auto-fill demo identity
          </button>
        </div>
      </div>

      <form onSubmit={handleSubmit}>
        <div className="form-grid">
          <div className="field-group">
            <div className="field-label">
              <span>National Identity Number (NIN)</span>
              <span className="badge-hint">private witness</span>
            </div>
            <input
              className="input-control"
              name="nin"
              value={form.nin}
              onChange={handleChange}
              placeholder="11-digit NIN"
              required
            />
          </div>

          <div className="field-group">
            <div className="field-label">
              <span>Fingerprint Biometric Hash</span>
              <span className="badge-hint">private witness</span>
            </div>
            <input
              className="input-control"
              name="fingerprintHash"
              value={form.fingerprintHash}
              onChange={handleChange}
              placeholder="64-character SHA-256 hex digest"
              required
            />
          </div>

          <div className="field-group">
            <div className="field-label">
              <span>Mobile Number (MSISDN)</span>
              <span className="badge-hint">on-ledger</span>
            </div>
            <input
              className="input-control"
              name="msisdn"
              value={form.msisdn}
              onChange={handleChange}
              placeholder="08011223344"
              required
            />
          </div>

          <div className="field-group">
            <div className="field-label">
              <span>Originating Operator</span>
              <span className="badge-hint">consensus member</span>
            </div>
            <select className="input-control" name="mno" value={form.mno} onChange={handleChange}>
              {MNOS.map(m => (
                <option key={m.id} value={m.id}>{m.name} ({m.msp})</option>
              ))}
            </select>
          </div>
        </div>

        <button type="submit" className="btn-primary" disabled={loading}>
          {loading ? (
            <>
              <div className="spinner" />
              <span>Processing cryptographic pipeline…</span>
            </>
          ) : (
            <>
              {selectedMNO && <span className={`mno-pip ${selectedMNO.pip}`} />}
              <span>Commit to Ledger</span>
            </>
          )}
        </button>
      </form>

      {/* Pipeline stepper */}
      {loading && (
        <div className="pipeline-track">
          {STEPS.map((label, i) => {
            const step = i + 1;
            const isDone = stepProgress > step;
            const isActive = stepProgress === step;
            let cls = 'pipeline-step';
            if (isDone) cls += ' done';
            else if (isActive) cls += ' active';

            return (
              <div className={cls} key={step}>
                <div className="step-indicator">
                  {isActive ? <div className="spinner" /> : isDone ? '✓' : step}
                </div>
                <span>{step}. {label}</span>
              </div>
            );
          })}
        </div>
      )}

      {/* Committed result */}
      {result && (
        <div className="output-card">
          <div className="output-header">
            <div className="output-title">
              <span>✓</span>
              <span>Registration committed to ledger</span>
            </div>
            <span className="badge badge-active">ACTIVE</span>
          </div>

          <div style={{ display: 'flex', flexDirection: 'column', gap: '14px' }}>
            {[
              { label: 'Subscriber ID', value: result.subscriberID, key: 'subscriberID' },
              { label: 'Identity Commitment', value: result.commitment, key: 'commitment' },
              { label: 'Encrypted IPFS CID', value: result.ipfsHash, key: 'ipfsHash' },
            ].map(field => (
              <div key={field.key}>
                <div style={{ fontSize: '0.78rem', color: 'var(--muted)', marginBottom: '4px' }}>
                  {field.label}
                </div>
                <div className="mono-field">
                  <span title={field.value}>{truncate(field.value)}</span>
                  <button
                    className="copy-btn"
                    onClick={() => copyToClipboard(field.value, field.key)}
                  >
                    {copiedField === field.key ? 'Copied' : 'Copy'}
                  </button>
                </div>
              </div>
            ))}
          </div>
        </div>
      )}

      {/* Error */}
      {error && (
        <div className="output-card output-card--error">
          <div style={{ color: 'var(--caution)', fontWeight: 600, fontSize: '0.88rem' }}>
            Registration rejected — {error}
          </div>
          <div style={{ color: 'var(--muted)', fontSize: '0.82rem', marginTop: '6px' }}>
            Verify all fields and retry. If the error persists, check the backend connection.
          </div>
        </div>
      )}
    </div>
  );
}
