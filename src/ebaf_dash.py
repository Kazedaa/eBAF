#!/usr/bin/env python3
import http.server            # For serving HTTP requests.
import socketserver         # To create a simple HTTP server.
import subprocess           # To run external commands (e.g., pgrep, ip link).
import json                 # For encoding/decoding JSON data.
import time                 # To handle time-related functionality.
import os                   # For OS-related functions (e.g., checking file existence).
import re                   # For regex operations.
from datetime import datetime  # To generate formatted timestamps.

# DashboardHandler extends SimpleHTTPRequestHandler to serve both HTML and API endpoints.
class DashboardHandler(http.server.SimpleHTTPRequestHandler):
    # Overrides the GET HTTP method.
    def do_GET(self):
        if self.path == '/':
            self.serve_dashboard()  # Serve the main dashboard page.
        elif self.path == '/api/stats':
            self.serve_api()        # Serve JSON API with statistics.
        else:
            self.send_error(404)    # Return 404 for unknown paths.

    # Serve an HTML dashboard page.
    def serve_dashboard(self):
        self.send_response(200)
        self.send_header('Content-type', 'text/html')
        self.end_headers()
        
        stats = self.get_stats()       # Gather current statistics.
        html = self.generate_html(stats)  # Generate dashboard HTML using stats.
        self.wfile.write(html.encode())

    # Serve statistics as JSON format for API consumers.
    def serve_api(self):
        self.send_response(200)
        self.send_header('Content-type', 'application/json')
        self.send_header('Access-Control-Allow-Origin', '*')  # Allow CORS.
        self.end_headers()
        
        stats = self.get_stats()       # Collect statistics.
        self.wfile.write(json.dumps(stats).encode())

    # Helper function to gather live statistics and system status.
    def get_stats(self):
        # Initialize default stats.
        stats = {
            'timestamp': datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
            'running': False,
            'interface': 'Unknown',
            'runtime': 'Unknown',
            'total_packets': 0,
            'blocked_packets': 0,
            'blocking_rate': 0.0,
            'total_rate': 0.0,
            'blocked_rate': 0.0,
            'blocked_domains': []
        }

        # Check if eBAF (the userspace program loading the eBPF XDP program) is running.
        # pgrep is used to search for a process with 'adblocker' in its command-line.
        try:
            result = subprocess.run(['pgrep', '-f', 'adblocker'], capture_output=True, text=True)
            stats['running'] = result.returncode == 0
        except:
            pass

        # Find the network interface with an attached XDP program.
        # eBPF XDP programs are attached at the network driver level.
        try:
            result = subprocess.run(['ip', 'link', 'show'], capture_output=True, text=True)
            lines = result.stdout.split('\n')
            for i, line in enumerate(lines):
                if 'xdp' in line.lower():
                    # Retrieve the interface name from the previous line using regex.
                    if i > 0:
                        match = re.search(r'\d+:\s+(\w+):', lines[i-1])
                        if match:
                            stats['interface'] = match.group(1)
                            break
        except:
            pass

        # Get approximate runtime from system uptime.
        try:
            result = subprocess.run(['uptime', '-p'], capture_output=True, text=True)
            stats['runtime'] = result.stdout.strip().replace('up ', '')
        except:
            pass

        # Read statistics from a temporary file created by the userspace program.
        # This file is populated by the eBPF program via updating maps and is read periodically.
        stats_file = '/tmp/ebaf-stats.dat'
        if os.path.exists(stats_file):
            try:
                with open(stats_file, 'r') as f:
                    for line in f:
                        if line.startswith('total:'):
                            stats['total_packets'] = int(line.split(':')[1].strip())
                        elif line.startswith('blocked:'):
                            stats['blocked_packets'] = int(line.split(':')[1].strip())
            except:
                pass

        # Calculate the percentage of blocked packets.
        if stats['total_packets'] > 0:
            stats['blocking_rate'] = (stats['blocked_packets'] / stats['total_packets']) * 100

        # Live rate calculations: compute packets per second between current and previous stats snapshot.
        prev_stats_file = '/tmp/ebaf-web-prev-stats.dat'
        current_time = time.time()
        
        if os.path.exists(prev_stats_file):
            try:
                with open(prev_stats_file, 'r') as f:
                    prev_data = json.load(f)
                    time_diff = current_time - prev_data['timestamp']
                    if time_diff > 0:
                        stats['total_rate'] = (stats['total_packets'] - prev_data['total_packets']) / time_diff
                        stats['blocked_rate'] = (stats['blocked_packets'] - prev_data['blocked_packets']) / time_diff
            except:
                pass

        # Save current snapshot of stats for live rate calculation on the next iteration.
        try:
            with open(prev_stats_file, 'w') as f:
                json.dump({
                    'timestamp': current_time,
                    'total_packets': stats['total_packets'],
                    'blocked_packets': stats['blocked_packets']
                }, f)
        except:
            pass

        # Retrieve a list of recently blocked domains. This can be expanded to read log files or BPF map dumps.
        stats['blocked_domains'] = self.get_blocked_domains()

        return stats

    # Stub function to get recently blocked domains.
    # In a full implementation, this could extract domain names from logs or BPF statistics.
    def get_blocked_domains(self):
        """Get recently blocked domains - simplified version"""
        blocked_domains = []
        # Implementation can be enhanced to actually track blocked domains.
        return blocked_domains

    # Generate HTML dashboard using the collected statistics.
    def generate_html(self, stats):
        # Determine status display based on whether eBAF is running.
        status_color = '#00ff41' if stats['running'] else '#ff4444'
        status_text = '✓ Running' if stats['running'] else '✗ Stopped'
        
        # Generate simple bar chart data for packet rates.
        max_rate = max(stats['total_rate'], 10)  # Set a minimum scale.
        total_bar_height = min((stats['total_rate'] / max_rate) * 100, 100)
        blocked_bar_height = min((stats['blocked_rate'] / max_rate) * 100, 100)
        
        # Return an HTML page that includes auto-refresh meta tag, CSS styling, and inline stats.
        return f"""
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>eBAF Dashboard</title>
    <meta http-equiv="refresh" content="3">
    <style>
        /* CSS styles for dashboard layout and visual elements */
        * {{
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }}
        
        body {{
            font-family: 'Courier New', monospace;
            background: linear-gradient(135deg, #0c0c0c 0%, #1a1a2e 50%, #16213e 100%);
            color: #00ff41;
            min-height: 100vh;
            padding: 20px;
        }}
        
        .container {{
            max-width: 1200px;
            margin: 0 auto;
        }}
        
        .header {{
            text-align: center;
            margin-bottom: 30px;
            padding: 20px;
            background: rgba(0, 255, 65, 0.1);
            border: 2px solid #00ff41;
            border-radius: 10px;
            box-shadow: 0 0 20px rgba(0, 255, 65, 0.3);
        }}
        
        .header h1 {{
            font-size: 2.5em;
            margin-bottom: 10px;
            text-shadow: 0 0 10px #00ff41;
        }}
        
        .grid {{
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
            gap: 20px;
            margin-bottom: 30px;
        }}
        
        .card {{
            background: rgba(0, 0, 0, 0.7);
            border: 2px solid #00ff41;
            border-radius: 10px;
            padding: 20px;
            box-shadow: 0 0 15px rgba(0, 255, 65, 0.2);
        }}
        
        .card h2 {{
            color: #00ff41;
            margin-bottom: 15px;
            font-size: 1.3em;
            text-align: center;
        }}
        
        .status {{
            color: {status_color};
            font-size: 1.2em;
            font-weight: bold;
        }}
        
        .metric {{
            display: flex;
            justify-content: space-between;
            margin: 10px 0;
            padding: 5px 0;
            border-bottom: 1px solid rgba(0, 255, 65, 0.3);
        }}
        
        .metric:last-child {{
            border-bottom: none;
        }}
        
        .metric-label {{
            color: #88cc88;
        }}
        
        .metric-value {{
            color: #00ff41;
            font-weight: bold;
        }}
        
        .progress-bar {{
            width: 100%;
            height: 20px;
            background: rgba(0, 0, 0, 0.5);
            border: 1px solid #00ff41;
            border-radius: 10px;
            overflow: hidden;
            margin: 10px 0;
        }}
        
        .progress-fill {{
            height: 100%;
            background: linear-gradient(90deg, #ff4444, #ffaa00, #00ff41);
            transition: width 0.5s ease;
            border-radius: 10px;
        }}
        
        .chart {{
            width: 100%;
            height: 120px;
            background: rgba(0, 0, 0, 0.3);
            border: 1px solid #00ff41;
            border-radius: 5px;
            position: relative;
            display: flex;
            align-items: end;
            justify-content: center;
            gap: 20px;
            padding: 10px;
        }}
        
        .chart-bar {{
            width: 30px;
            background: #00ff41;
            border-radius: 3px 3px 0 0;
            transition: height 0.5s ease;
            position: relative;
        }}
        
        .chart-bar.total {{
            background: #00aaff;
        }}
        
        .chart-bar.blocked {{
            background: #ff4444;
        }}
        
        .chart-label {{
            position: absolute;
            bottom: -25px;
            left: 50%;
            transform: translateX(-50%);
            font-size: 0.8em;
            color: #88cc88;
        }}
        
        .domain-list {{
            max-height: 150px;
            overflow-y: auto;
        }}
        
        .domain-item {{
            padding: 5px 0;
            border-bottom: 1px solid rgba(0, 255, 65, 0.2);
            font-size: 0.9em;
        }}
        
        .no-data {{
            text-align: center;
            color: #666;
            font-style: italic;
            padding: 20px;
        }}
        
        .alert {{
            background: rgba(255, 68, 68, 0.2);
            border: 2px solid #ff4444;
            color: #ff4444;
            padding: 15px;
            border-radius: 10px;
            margin-bottom: 20px;
            text-align: center;
        }}
        
        .footer {{
            text-align: center;
            margin-top: 30px;
            padding: 15px;
            color: #666;
        }}
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🛡️ eBAF Dashboard</h1>
            <p>eBPF Ad Blocker Firewall</p>
            <p>Last Updated: {stats['timestamp']}</p>
        </div>
        
        {'<div class="alert">⚠️ eBAF is not running! Start it with: sudo ebaf</div>' if not stats['running'] else ''}
        
        <div class="grid">
            <div class="card">
                <h2>📊 General Status</h2>
                <div class="metric">
                    <span class="metric-label">Status:</span>
                    <span class="metric-value status">{status_text}</span>
                </div>
                <div class="metric">
                    <span class="metric-label">Runtime:</span>
                    <span class="metric-value">{stats['runtime']}</span>
                </div>
                <div class="metric">
                    <span class="metric-label">Interface:</span>
                    <span class="metric-value">{stats['interface']}</span>
                </div>
            </div>
            
            <div class="card">
                <h2>📈 Packet Statistics</h2>
                <div class="metric">
                    <span class="metric-label">Total Packets:</span>
                    <span class="metric-value">{stats['total_packets']:,}</span>
                </div>
                <div class="metric">
                    <span class="metric-label">Blocked Packets:</span>
                    <span class="metric-value">{stats['blocked_packets']:,}</span>
                </div>
                <div class="metric">
                    <span class="metric-label">Blocking Rate:</span>
                    <span class="metric-value">{stats['blocking_rate']:.2f}%</span>
                </div>
                <div class="progress-bar">
                    <div class="progress-fill" style="width: {min(stats['blocking_rate'], 100)}%"></div>
                </div>
            </div>
            
            <div class="card">
                <h2>⚡ Live Rates</h2>
                <div class="metric">
                    <span class="metric-label">Total Rate:</span>
                    <span class="metric-value">{stats['total_rate']:.1f} pkt/s</span>
                </div>
                <div class="metric">
                    <span class="metric-label">Blocked Rate:</span>
                    <span class="metric-value">{stats['blocked_rate']:.1f} pkt/s</span>
                </div>
                <div class="chart">
                    <div class="chart-bar total" style="height: {total_bar_height}%">
                        <div class="chart-label">Total</div>
                    </div>
                    <div class="chart-bar blocked" style="height: {blocked_bar_height}%">
                        <div class="chart-label">Blocked</div>
                    </div>
                </div>
            </div>
            
            <div class="card">
                <h2>🚫 Recently Blocked</h2>
                <div class="domain-list">
                    {''.join([f'<div class="domain-item">{domain}</div>' for domain in stats['blocked_domains']]) if stats['blocked_domains'] else '<div class="no-data">No recent blocks recorded</div>'}
                </div>
            </div>
        </div>
        
        <div class="footer">
            <p>🛡️ eBAF Dashboard - Auto-refresh every 3 seconds</p>
        </div>
    </div>
</body>
</html>
"""

# Start the dashboard server on a specified port.
def start_dashboard(port=8080):
    """Start the dashboard server"""
    try:
        Handler = DashboardHandler
        # Create a TCP server that listens on all interfaces on the chosen port.
        with socketserver.TCPServer(("", port), Handler) as httpd:
            print(f"🌐 eBAF Dashboard started at http://localhost:{port}")
            print("Press Ctrl+C to stop the dashboard")
            httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n👋 Dashboard stopped")
    except Exception as e:
        print(f"❌ Error starting dashboard: {e}")

if __name__ == "__main__":
    import sys
    port = 8080
    # Allow the port to be customized via command-line argument.
    if len(sys.argv) > 1:
        try:
            port = int(sys.argv[1])
        except ValueError:
            print("Invalid port number, using default 8080")
    
    start_dashboard(port)