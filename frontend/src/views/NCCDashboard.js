import React, { useState, useEffect, useRef } from 'react';

const OPERATORS = [
  { id: 'ALL', name: 'All MNOs' },
  { id: 'MTN', name: 'MTN Nigeria' },
  { id: 'Airtel', name: 'Airtel Nigeria' },
  { id: 'Glo', name: 'Globacom (Glo)' },
  { id: 'NineMobile', name: '9mobile' },
];

export default function NCCDashboard() {
  const [viewMode, setViewMode] = useState('AUDIT'); // 'AUDIT' or 'SUBSCRIBERS'
  const [subscriberID, setSubscriberID] = useState('');
  const [activeFilter, setActiveFilter] = useState('');
  const [mnoFilter, setMnoFilter] = useState('ALL');
  const [identitySearch, setIdentitySearch] = useState('');

  const [events, setEvents] = useState([]);
  const [subscribers, setSubscribers] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const [copiedKey, setCopiedKey] = useState('');
  const intervalRef = useRef(null);

  const fetchAudit = async sid => {
    try {
      const url = sid ? `/api/audit/${encodeURIComponent(sid.trim())}` : '/api/audit/all';
      const res = await fetch(url);
      const data = await res.json();
      if (!res.ok) throw new Error(data.error || 'Fetch failed');
      setEvents(Array.isArray(data) ? data : []);
      setError(null);
    } catch (err) {
      setError(err.message);
    } finally {
      setLoading(false);
    }
  };

  const fetchSubscribers = async () => {
    try {
      const res = await fetch('/api/registration/subscribers/all');
      const data = await res.json();
      if (!res.ok) throw new Error(data.error || 'Fetch subscribers failed');
      setSubscribers(Array.isArray(data) ? data : []);
      setError(null);
    } catch (err) {
      setError(err.message);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    if (viewMode === 'AUDIT') {
      fetchAudit(activeFilter);
      intervalRef.current = setInterval(() => fetchAudit(activeFilter), 4000);
    } else {
      fetchSubscribers();
      intervalRef.current = setInterval(fetchSubscribers, 4000);
    }
    return () => clearInterval(intervalRef.current);
  }, [viewMode, activeFilter]);

  const handleSearch = e => {
    e.preventDefault();
    setLoading(true);
    setActiveFilter(subscriberID);
  };

  const handleClearFilter = () => {
    setSubscriberID('');
    setActiveFilter('');
    setLoading(true);
  };

  const copyToClipboard = (text, key) => {
    if (!text) return;
    navigator.clipboard.writeText(text);
    setCopiedKey(key);
    setTimeout(() => setCopiedKey(''), 2000);
  };

  // Filter subscribers list by MNO and Identity Search
  const filteredSubscribers = subscribers.filter(sub => {
    const matchesMno = mnoFilter === 'ALL' || (sub.mno || '').toUpperCase().includes(mnoFilter.toUpperCase());
    const query = identitySearch.trim().toLowerCase();
    const matchesIdentity = !query ||
      (sub.identityCommit || '').toLowerCase().includes(query) ||
      (sub.msisdn || '').toLowerCase().includes(query) ||
      (sub.subscriberID || '').toLowerCase().includes(query);
    return matchesMno && matchesIdentity;
  });

  return (
    <div className="panel panel--ncc">
      <div className="panel-header">
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', flexWrap: 'wrap', gap: '12px' }}>
          <div>
            <h2>{viewMode === 'AUDIT' ? 'NCC Regulatory Audit Log' : 'National SIM Register Overview'}</h2>
            <p>{viewMode === 'AUDIT' ? 'Immutable append-only event trail — queried directly from update-tracking contract' : 'Regulatory directory — inspection by Network Operator (MNO) and Identity Commitment'}</p>
          </div>
          
          <div style={{ display: 'flex', alignItems: 'center', gap: '12px' }}>
            <div style={{ display: 'flex', background: 'var(--parchment-deep)', padding: '3px', borderRadius: '8px', border: '1px solid var(--rule-light)' }}>
              <button
                type="button"
                className={`btn-secondary ${viewMode === 'AUDIT' ? 'btn-primary' : ''}`}
                onClick={() => { setViewMode('AUDIT'); setLoading(true); }}
                style={{ fontSize: '0.78rem', padding: '6px 12px' }}
              >
                📜 Audit Logs
              </button>
              <button
                type="button"
                className={`btn-secondary ${viewMode === 'SUBSCRIBERS' ? 'btn-primary' : ''}`}
                onClick={() => { setViewMode('SUBSCRIBERS'); setLoading(true); }}
                style={{ fontSize: '0.78rem', padding: '6px 12px' }}
              >
                👥 All Subscribers ({subscribers.length})
              </button>
            </div>

            <div style={{
              display: 'flex',
              alignItems: 'center',
              gap: '6px',
              fontSize: '0.75rem',
              fontWeight: 600,
              color: 'var(--seal)',
              background: 'var(--seal-light)',
              padding: '5px 12px',
              borderRadius: '9999px',
              border: '1px solid var(--seal-border)',
            }}>
              <span className="status-dot" />
              <span>Live (4s)</span>
            </div>
          </div>
        </div>
      </div>

      {viewMode === 'AUDIT' && (
        <>
          <form onSubmit={handleSearch} style={{ marginBottom: '20px' }}>
            <div style={{ display: 'flex', gap: '12px' }}>
              <input
                className="input-control"
                value={subscriberID}
                onChange={e => setSubscriberID(e.target.value)}
                placeholder="Filter by Subscriber ID (leave blank to stream all system logs)"
                style={{ flex: 1, fontFamily: 'var(--font-mono)' }}
              />
              <button type="submit" className="btn-primary" style={{ minWidth: '140px' }}>
                Filter Trail
              </button>
              {activeFilter && (
                <button type="button" className="btn-secondary" onClick={handleClearFilter}>
                  Show All Logs
                </button>
              )}
            </div>
          </form>

          {loading && events.length === 0 && (
            <div className="output-card" style={{ textAlign: 'center', color: 'var(--muted)' }}>
              Fetching regulatory audit logs from ledger…
            </div>
          )}

          {!loading && events.length > 0 && (
            <div className="table-container">
              <table className="data-table">
                <thead>
                  <tr>
                    <th>Event ID</th>
                    <th>Subscriber ID</th>
                    <th>Type</th>
                    <th>Originating MNO</th>
                    <th>Ledger Timestamp</th>
                    <th>Details</th>
                  </tr>
                </thead>
                <tbody>
                  {events.map((ev, idx) => {
                    const eventIdKey = `evt_${idx}_${ev.eventID}`;
                    const subIdKey = `sub_${idx}_${ev.subscriberID}`;
                    return (
                      <tr key={ev.eventID || ev._id || idx} className="audit-row">
                        <td>
                          <div style={{ display: 'flex', alignItems: 'center', gap: '6px' }}>
                            <span className="badge badge-mno" style={{ fontFamily: 'var(--font-mono)', fontSize: '0.75rem' }}>
                              {(ev.eventID || '').slice(0, 12)}…
                            </span>
                            <button
                              type="button"
                              className="btn-secondary"
                              onClick={() => copyToClipboard(ev.eventID, eventIdKey)}
                              style={{ fontSize: '0.7rem', padding: '2px 6px', lineHeight: 1 }}
                              title="Copy full Event ID"
                            >
                              {copiedKey === eventIdKey ? '✓' : '📋'}
                            </button>
                          </div>
                        </td>
                        <td>
                          <div style={{ display: 'flex', alignItems: 'center', gap: '6px' }}>
                            <span style={{ fontFamily: 'var(--font-mono)', fontSize: '0.78rem' }}>
                              {(ev.subscriberID || '').slice(0, 14)}…
                            </span>
                            <button
                              type="button"
                              className="btn-secondary"
                              onClick={() => copyToClipboard(ev.subscriberID, subIdKey)}
                              style={{ fontSize: '0.7rem', padding: '2px 6px', lineHeight: 1 }}
                              title="Copy full Subscriber ID"
                            >
                              {copiedKey === subIdKey ? '✓ Copied' : '📋 Copy'}
                            </button>
                          </div>
                        </td>
                        <td><span className="badge badge-event">{ev.eventType}</span></td>
                        <td><span className="badge badge-mno">{ev.mno}</span></td>
                        <td style={{ fontFamily: 'var(--font-mono)', fontSize: '0.8rem' }}>{ev.timestamp}</td>
                        <td style={{ fontSize: '0.82rem' }}>{ev.details}</td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          )}
        </>
      )}

      {viewMode === 'SUBSCRIBERS' && (
        <>
          {/* MNO Filter Tabs & Identity Search Bar */}
          <div style={{ display: 'flex', flexDirection: 'column', gap: '12px', marginBottom: '20px' }}>
            <div style={{ display: 'flex', gap: '8px', flexWrap: 'wrap' }}>
              {OPERATORS.map(op => (
                <button
                  key={op.id}
                  type="button"
                  className={`btn-secondary ${mnoFilter === op.id ? 'btn-primary' : ''}`}
                  onClick={() => setMnoFilter(op.id)}
                  style={{ fontSize: '0.82rem', padding: '6px 14px' }}
                >
                  {op.name}
                </button>
              ))}
            </div>

            <div style={{ display: 'flex', gap: '12px' }}>
              <input
                className="input-control"
                value={identitySearch}
                onChange={e => setIdentitySearch(e.target.value)}
                placeholder="Search by ZK Identity Commitment, Phone Number, or Subscriber ID…"
                style={{ flex: 1, fontFamily: 'var(--font-mono)' }}
              />
              {identitySearch && (
                <button type="button" className="btn-secondary" onClick={() => setIdentitySearch('')}>
                  Clear Search
                </button>
              )}
            </div>
          </div>

          {loading && subscribers.length === 0 && (
            <div className="output-card" style={{ textAlign: 'center', color: 'var(--muted)' }}>
              Fetching national SIM directory from ledger…
            </div>
          )}

          {!loading && (
            <>
              <div className="output-card" style={{ marginBottom: '16px', background: 'var(--parchment-deep)' }}>
                <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
                  <span style={{ fontSize: '0.88rem', fontWeight: 600, color: 'var(--ink)' }}>
                    Displaying <strong>{filteredSubscribers.length}</strong> registered SIM(s)
                    {mnoFilter !== 'ALL' && ` for ${OPERATORS.find(o => o.id === mnoFilter)?.name}`}
                    {identitySearch && ` matching "${identitySearch}"`}
                  </span>
                  <span className="badge badge-active">
                    Regulator Master Inspection
                  </span>
                </div>
              </div>

              {filteredSubscribers.length > 0 ? (
                <div className="table-container">
                  <table className="data-table">
                    <thead>
                      <tr>
                        <th>Subscriber ID</th>
                        <th>Phone Number (MSISDN)</th>
                        <th>Network Operator</th>
                        <th>Status</th>
                        <th>ZK Identity Commitment</th>
                        <th>Registration Date</th>
                      </tr>
                    </thead>
                    <tbody>
                      {filteredSubscribers.map((sub, idx) => {
                        const subIdKey = `allsub_${idx}_${sub.subscriberID}`;
                        return (
                          <tr key={sub.subscriberID || idx} className="audit-row">
                            <td>
                              <div style={{ display: 'flex', alignItems: 'center', gap: '6px' }}>
                                <span style={{ fontFamily: 'var(--font-mono)', fontSize: '0.78rem' }}>
                                  {(sub.subscriberID || '').slice(0, 14)}…
                                </span>
                                <button
                                  type="button"
                                  className="btn-secondary"
                                  onClick={() => copyToClipboard(sub.subscriberID, subIdKey)}
                                  style={{ fontSize: '0.7rem', padding: '2px 6px', lineHeight: 1 }}
                                  title="Copy full Subscriber ID"
                                >
                                  {copiedKey === subIdKey ? '✓ Copied' : '📋 Copy'}
                                </button>
                              </div>
                            </td>
                            <td style={{ fontFamily: 'var(--font-mono)', fontWeight: 600 }}>{sub.msisdn}</td>
                            <td><span className="badge badge-mno">{sub.mno}</span></td>
                            <td>
                              <span className={`badge ${sub.status === 'ACTIVE' ? 'badge-active' : 'badge-deactivated'}`}>
                                {sub.status}
                              </span>
                            </td>
                            <td>
                              <span
                                className="mono-field"
                                style={{ fontSize: '0.75rem', cursor: 'pointer' }}
                                onClick={() => setIdentitySearch(sub.identityCommit)}
                                title="Click to filter all SIMs under this Identity Commitment"
                              >
                                {(sub.identityCommit || '').slice(0, 16)}…
                              </span>
                            </td>
                            <td style={{ fontFamily: 'var(--font-mono)', fontSize: '0.8rem' }}>{sub.registeredAt}</td>
                          </tr>
                        );
                      })}
                    </tbody>
                  </table>
                </div>
              ) : (
                <div className="output-card" style={{ textAlign: 'center', color: 'var(--muted)' }}>
                  No subscriber records matched the selected MNO filter or search term.
                </div>
              )}
            </>
          )}
        </>
      )}

      {error && (
        <div className="output-card output-card--error">
          <div style={{ color: 'var(--caution)', fontWeight: 600, fontSize: '0.88rem' }}>
            Query failed — {error}
          </div>
        </div>
      )}
    </div>
  );
}
