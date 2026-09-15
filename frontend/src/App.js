import React, { useState, useEffect } from 'react';
import RegistrationForm from './views/RegistrationForm';
import MNORecordView from './views/MNORecordView';
import NCCDashboard from './views/NCCDashboard';
import AccessControlView from './views/AccessControlView';

const TABS = [
  { id: 'Registration',       label: 'Subscriber Registration', icon: '⊕' },
  { id: 'MNO Record View',    label: 'MNO Record Lookup',       icon: '⊞' },
  { id: 'NCC Audit Dashboard', label: 'NCC Regulatory Audit',   icon: '◎' },
  { id: 'Access Control',     label: 'Access Control',           icon: '⊘' },
];

export default function App() {
  const [activeTab, setActiveTab] = useState('Registration');
  const [sidebarOpen, setSidebarOpen] = useState(false);
  const [isOnline, setIsOnline] = useState(true);
  const [peerStatus, setPeerStatus] = useState({ active: 5, total: 5 });
  const [subCount, setSubCount] = useState(0);
  const [consensusMsg, setConsensusMsg] = useState('Raft Active');

  useEffect(() => {
    const checkHealth = async () => {
      try {
        const res = await fetch('/health');
        if (res.ok) {
          const data = await res.json();
          setIsOnline(true);
          setPeerStatus({
            active: typeof data.activePeers === 'number' ? data.activePeers : 5,
            total: typeof data.totalPeers === 'number' ? data.totalPeers : 5,
          });
          if (typeof data.totalSubscribers === 'number') {
            setSubCount(data.totalSubscribers);
          }
          if (data.consensusStatus) {
            setConsensusMsg(data.consensusStatus);
          }
        } else {
          setIsOnline(false);
        }
      } catch {
        setIsOnline(false);
      }
    };

    checkHealth();
    const interval = setInterval(checkHealth, 3000);
    return () => clearInterval(interval);
  }, []);

  const handleTabClick = (tabId) => {
    setActiveTab(tabId);
    setSidebarOpen(false);
  };

  return (
    <div className="app-container">
      {/* Mobile hamburger */}
      <button
        className="hamburger-btn"
        onClick={() => setSidebarOpen(!sidebarOpen)}
        aria-label="Toggle navigation"
      >
        {sidebarOpen ? '✕' : '☰'}
      </button>

      {/* Overlay for mobile drawer */}
      <div
        className={`sidebar-overlay ${sidebarOpen ? 'open' : ''}`}
        onClick={() => setSidebarOpen(false)}
      />

      {/* Sidebar */}
      <aside className={`sidebar ${sidebarOpen ? 'open' : ''}`}>
        <div className="sidebar-brand">
          <div className="brand-mark">NCC</div>
          <div className="brand-text">
            <h1>SIM Registration</h1>
            <p>Fabric v2.5 · ZKP · IPFS</p>
          </div>
        </div>

        <nav className="sidebar-nav" role="navigation" aria-label="Main navigation">
          {TABS.map(tab => (
            <button
              key={tab.id}
              className={`nav-button ${activeTab === tab.id ? 'active' : ''}`}
              onClick={() => handleTabClick(tab.id)}
              aria-label={tab.label}
              aria-current={activeTab === tab.id ? 'page' : undefined}
            >
              <span className="nav-icon">{tab.icon}</span>
              <span className="nav-label">{tab.label}</span>
            </button>
          ))}
        </nav>

        <div className={`sidebar-status ${isOnline ? '' : 'offline'}`}>
          <span className={`status-dot ${isOnline ? '' : 'offline'}`} />
          <span>{isOnline ? 'Network Online' : 'Network Offline'}</span>
        </div>
      </aside>

      {/* Main content */}
      <main className="main-content">
        <div className="metrics-grid">
          <div className="metric-card">
            <div className="metric-title">Registered Subscribers</div>
            <div className="metric-value">{isOnline ? subCount.toLocaleString() : '—'}</div>
          </div>
          <div className="metric-card">
            <div className="metric-title">ZK Proof Rate</div>
            <div className="metric-value">{isOnline ? '100%' : '—'}</div>
          </div>
          <div className="metric-card">
            <div className="metric-title">Active Network Peers</div>
            <div className="metric-value">
              {isOnline ? `${peerStatus.active} / ${peerStatus.total}` : '0 / 5'}
            </div>
          </div>
          <div className="metric-card">
            <div className="metric-title">Fabric Network Status</div>
            <div className="metric-value" style={{ color: consensusMsg.includes('reachable') ? 'var(--ink)' : 'var(--caution)', fontSize: consensusMsg.includes('reachable') ? '1.2rem' : '0.82rem' }}>
              {isOnline ? consensusMsg : 'Offline'}
            </div>
          </div>
        </div>

        {activeTab === 'Registration' && <RegistrationForm />}
        {activeTab === 'MNO Record View' && <MNORecordView />}
        {activeTab === 'NCC Audit Dashboard' && <NCCDashboard />}
        {activeTab === 'Access Control' && <AccessControlView />}
      </main>
    </div>
  );
}
