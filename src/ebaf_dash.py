#!/usr/bin/env python3
import http.server            # For serving HTTP requests.
import socketserver         # To create a simple HTTP server.
import subprocess           # To run external commands (e.g., pgrep, ip link).
import json                 # For encoding/decoding JSON data.
import time                 # To handle time-related functionality.
import os                   # For OS-related functions (e.g., checking file existence).
import re                   # For regex operations.
from datetime import datetime  # To generate formatted timestamps.

# Global variable to track dashboard start time
DASHBOARD_START_TIME = time.time()

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
            'blocked_domains': [],
            'rate_history': []
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
        stats['interface'] = self.get_xdp_interface()

        # Calculate dashboard runtime
        runtime_seconds = int(time.time() - DASHBOARD_START_TIME)
        hours = runtime_seconds // 3600
        minutes = (runtime_seconds % 3600) // 60
        seconds = runtime_seconds % 60
        
        if hours > 0:
            stats['runtime'] = f"{hours}h {minutes}m {seconds}s"
        elif minutes > 0:
            stats['runtime'] = f"{minutes}m {seconds}s"
        else:
            stats['runtime'] = f"{seconds}s"

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

        # Get rate history for the graph
        stats['rate_history'] = self.get_rate_history(stats['blocked_rate'])

        # Retrieve a list of recently blocked domains. This can be expanded to read log files or BPF map dumps.
        stats['blocked_domains'] = self.get_blocked_domains()

        return stats

    # Helper function to get the interface with XDP program attached
    def get_xdp_interface(self):
        try:
            result = subprocess.run(['ip', 'link', 'show'], capture_output=True, text=True)
            lines = result.stdout.split('\n')
            for i, line in enumerate(lines):
                if 'xdp' in line.lower() and 'prog' in line.lower():
                    # Get the interface name from the current or previous line
                    for j in range(max(0, i-2), min(len(lines), i+2)):
                        match = re.search(r'\d+:\s+(\w+):', lines[j])
                        if match:
                            return match.group(1)
        except:
            pass
        return 'Unknown'

    # Get rate history for time-series graph
    def get_rate_history(self, current_rate):
        history_file = '/tmp/ebaf-rate-history.json'
        history = []
        
        try:
            if os.path.exists(history_file):
                with open(history_file, 'r') as f:
                    history = json.load(f)
        except:
            history = []
        
        # Add current rate with timestamp
        current_time = datetime.now()
        history.append({
            'time': current_time.strftime("%H:%M:%S"),
            'rate': current_rate
        })
        
        # Keep only last 100 data points for full graph width utilization
        if len(history) > 100:
            history = history[-100:]
        
        # Save updated history
        try:
            with open(history_file, 'w') as f:
                json.dump(history, f)
        except:
            pass
        
        return history

    # Stub function to get recently blocked domains.
    # In a full implementation, this could extract domain names from logs or BPF statistics.
    def get_blocked_domains(self):
        """Get recently blocked domains - simplified version"""
        # This is a placeholder. In a real implementation, you would:
        # 1. Read from BPF maps or log files
        # 2. Parse domain names from blocked requests
        # 3. Return the most recently blocked domains
        return [
            "doubleclick.net",
            "googlesyndication.com", 
            "facebook.com/tr",
            "analytics.google.com",
            "ads.yahoo.com",
            "googletagmanager.com",
            "scorecardresearch.com",
            "outbrain.com",
            "taboola.com",
            "amazon-adsystem.com"
        ]

    # Generate HTML dashboard using the collected statistics.
    def generate_html(self, stats):
        # Determine status display based on whether eBAF is running.
        status_text = 'ACTIVE' if stats['running'] else 'INACTIVE'
        
        # Create clean line graph for blocked rate
        def create_rate_graph():
            if not stats['rate_history'] or len(stats['rate_history']) < 2:
                return "Collecting data..."
            
            # Find max rate for scaling, with minimum of 1 to avoid division by zero
            max_rate = max([point['rate'] for point in stats['rate_history']] + [1])
            
            # Graph dimensions
            height = 17
            width = min(400, len(stats['rate_history']) * 2)  # Dynamic width based on data
            
            # Create the graph grid
            graph_lines = []
            
            # Initialize empty grid
            grid = [[' ' for _ in range(width)] for _ in range(height)]
            
            # Plot the line
            data_points = stats['rate_history'][-width//2:]  # Use recent data points
            
            for i in range(len(data_points) - 1):
                if i * 2 >= width - 1:
                    break
                    
                # Current and next points
                curr_rate = (data_points[i]['rate'] / max_rate) * (height - 1)
                next_rate = (data_points[i + 1]['rate'] / max_rate) * (height - 1)
                
                # Draw line between points
                x1, y1 = i * 2, int(curr_rate)
                x2, y2 = min((i + 1) * 2, width - 1), int(next_rate)
                
                # Simple line drawing
                if x1 < width and y1 < height:
                    grid[height - 1 - y1][x1] = '●'
                if x2 < width and y2 < height:
                    grid[height - 1 - y2][x2] = '●'
                
                # Connect points with simple interpolation
                if abs(y2 - y1) > 1:
                    steps = abs(y2 - y1)
                    for step in range(1, steps):
                        interp_y = y1 + (y2 - y1) * step // steps
                        interp_x = x1 + (x2 - x1) * step // steps
                        if interp_x < width and 0 <= interp_y < height:
                            grid[height - 1 - interp_y][interp_x] = '●'
            
            # Convert grid to strings with Y-axis
            for row in range(height):
                line = "█|" + ''.join(grid[row])
                graph_lines.append(line)
            
            # Add X-axis
            x_axis = "█+" + "█" * width
            graph_lines.append(x_axis)
            
            return '\n'.join(graph_lines)

        
        rate_graph = create_rate_graph()
        
        # Return an HTML page that includes auto-refresh meta tag, CSS styling, and inline stats.
        return f"""
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>eBAF Terminal Dashboard</title>
    <meta http-equiv="refresh" content="3">
    <style>
        * {{
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }}
        
        body {{
            font-family: 'Courier New', 'Liberation Mono', 'DejaVu Sans Mono', monospace;
            background: #000000;
            color: #ffffff;
            line-height: 1.2;
            padding: 15px;
            font-size: 14px;
            height: 100vh;
            overflow: hidden;
        }}
        
        .terminal {{
            background: #000000;
            border: 2px solid #606060;
            border-radius: 0;
            padding: 25px;
            box-shadow: none;
            height: calc(100vh - 30px);
            overflow: hidden;
            display: flex;
            flex-direction: column;
        }}
        
        .header {{
            text-align: center;
            margin-bottom: 20px;
            border-bottom: 2px solid #606060;
            padding-bottom: 20px;
            flex-shrink: 0;
        }}
        
        .ascii-title {{
            color: #ffffff;
            font-size: 16px;
            line-height: 1;
            margin-bottom: 15px;
            white-space: pre;
            font-weight: bold;
        }}
        
        .tagline {{
            color: #00ff00;
            font-size: 18px;
            font-weight: bold;
            margin-top: 15px;
            text-transform: uppercase;
            letter-spacing: 2px;
        }}
        
        .main-content {{
            flex: 1;
            display: grid;
            grid-template-columns: 1fr 1fr 1fr;
            grid-template-rows: 1fr 1fr;
            gap: 20px;
            overflow: hidden;
        }}
        
        .section {{
            border: 2px solid #606060;
            padding: 15px;
            display: flex;
            flex-direction: column;
            overflow: hidden;
            background: #0a0a0a;
        }}
        
        .system-status {{
            grid-column: 1;
            grid-row: 1;
        }}
        
        .packet-stats {{
            grid-column: 2;
            grid-row: 1;
        }}
        
        .blocked-domains {{
            grid-column: 3;
            grid-row: 1 / 3;
        }}
        
        .graph-section {{
            grid-column: 1 / 3;
            grid-row: 2;
            border: 2px solid #606060;
            padding: 15px;
            background: #0a0a0a;
            display: flex;
            flex-direction: column;
            overflow: hidden;
        }}
        
        .section-title {{
            color: #00ff00;
            font-weight: bold;
            margin-bottom: 12px;
            border-bottom: 1px solid #606060;
            padding-bottom: 8px;
            font-size: 14px;
            flex-shrink: 0;
            text-transform: uppercase;
        }}
        
        .status-line {{
            display: flex;
            justify-content: space-between;
            margin: 8px 0;
            font-family: monospace;
            font-size: 13px;
        }}
        
        .status-active {{
            color: #00ff00;
            font-weight: bold;
        }}
        
        .status-inactive {{
            color: #ff0000;
            font-weight: bold;
        }}
        
        .graph {{
            font-family: monospace;
            color: #00ff00;
            white-space: pre;
            font-size: 10px;
            line-height: 1;
            text-align: left;
            flex: 1;
            overflow: hidden;
            font-weight: normal;
        }}
        
        .domains-list {{
            flex: 1;
            overflow: hidden;
            border: 1px solid #606060;
            padding: 10px;
            background: #050505;
            overflow-y: auto;
        }}
        
        .domain-item {{
            color: #ff6060;
            margin: 4px 0;
            font-family: monospace;
            font-size: 12px;
            font-weight: bold;
        }}
        
        .domain-item:before {{
            content: "> ";
            color: #00ff00;
        }}
        
        .no-domains {{
            color: #808080;
            font-style: italic;
            text-align: center;
            padding: 20px;
        }}
        
        .alert {{
            background: #330000;
            border: 2px solid #ff0000;
            color: #ff6060;
            padding: 10px;
            margin: 15px 0;
            text-align: center;
            font-weight: bold;
            text-transform: uppercase;
        }}
        
        .number-highlight {{
            color: #00ff00;
            font-weight: bold;
        }}
        
        .stats-content {{
            flex: 1;
            overflow: hidden;
        }}
        
        /* Hide scrollbars completely except for domains list */
        ::-webkit-scrollbar {{
            width: 6px;
        }}
        
        ::-webkit-scrollbar-track {{
            background: #000000;
        }}
        
        ::-webkit-scrollbar-thumb {{
            background: #606060;
            border-radius: 3px;
        }}
        
        ::-webkit-scrollbar-thumb:hover {{
            background: #808080;
        }}
        
        .label {{
            color: #c0c0c0;
        }}
        
        @media (max-width: 1200px) {{
            .main-content {{
                grid-template-columns: 1fr 1fr;
                grid-template-rows: auto auto auto;
            }}
            
            .system-status {{
                grid-column: 1;
                grid-row: 1;
            }}
            
            .packet-stats {{
                grid-column: 2;
                grid-row: 1;
            }}
            
            .blocked-domains {{
                grid-column: 1 / 3;
                grid-row: 2;
            }}
            
            .graph-section {{
                grid-column: 1 / 3;
                grid-row: 3;
            }}
        }}
        
        @media (max-width: 800px) {{
            .main-content {{
                grid-template-columns: 1fr;
                grid-template-rows: auto auto auto auto;
            }}
            
            .system-status {{
                grid-column: 1;
                grid-row: 1;
            }}
            
            .packet-stats {{
                grid-column: 1;
                grid-row: 2;
            }}
            
            .blocked-domains {{
                grid-column: 1;
                grid-row: 3;
            }}
            
            .graph-section {{
                grid-column: 1;
                grid-row: 4;
            }}
        }}
    </style>
</head>
<body>
    <div class="terminal">
        <div class="header">
            <div class="ascii-title">
           /$$$$$$$   /$$$$$$  /$$$$$$$$
          | $$__  $$ /$$__  $$| $$_____/
  /$$$$$$ | $$  \ $$| $$  \ $$| $$      
 /$$__  $$| $$$$$$$ | $$$$$$$$| $$$$$   
| $$$$$$$$| $$__  $$| $$__  $$| $$__/   
| $$_____/| $$  \ $$| $$  | $$| $$      
|  $$$$$$$| $$$$$$$/| $$  | $$| $$      
 \_______/|_______/ |__/  |__/|__/      
            </div>
            <div class="tagline">⚡ DROP ADS AT THE KERNEL ⚡</div>
        </div>
        
        {'<div class="alert">⚠ ERROR: eBAF process not running! Execute: sudo ebaf ⚠</div>' if not stats['running'] else ''}
        
        <div class="main-content">
            <div class="section system-status">
                <div class="section-title">[System Status]</div>
                <div class="stats-content">
                    <div class="status-line">
                        <span class="label">Service:</span>
                        <span class="{'status-active' if stats['running'] else 'status-inactive'}">{status_text}</span>
                    </div>
                    <div class="status-line">
                        <span class="label">Interface:</span>
                        <span class="number-highlight">{stats['interface']}</span>
                    </div>
                    <div class="status-line">
                        <span class="label">Runtime:</span>
                        <span class="number-highlight">{stats['runtime']}</span>
                    </div>
                </div>
            </div>
            
            <div class="section packet-stats">
                <div class="section-title">[Packet Stats]</div>
                <div class="stats-content">
                    <div class="status-line">
                        <span class="label">Total:</span>
                        <span class="number-highlight">{stats['total_packets']:,}</span>
                    </div>
                    <div class="status-line">
                        <span class="label">Blocked:</span>
                        <span class="number-highlight">{stats['blocked_packets']:,}</span>
                    </div>
                    <div class="status-line">
                        <span class="label">Total Rate:</span>
                        <span class="number-highlight">{stats['total_rate']:.1f}/s</span>
                    </div>
                    <div class="status-line">
                        <span class="label">Block Rate:</span>
                        <span class="number-highlight">{stats['blocked_rate']:.1f}/s</span>
                    </div>
                    <div class="status-line">
                        <span class="label">Block %:</span>
                        <span class="number-highlight">{stats['blocking_rate']:.1f}%</span>
                    </div>
                </div>
            </div>
            
            <div class="section blocked-domains">
                <div class="section-title">[Blocked Domains]</div>
                <div class="domains-list">
                    {''.join([f'<div class="domain-item">{domain}</div>' for domain in stats['blocked_domains']]) if stats['blocked_domains'] else '<div class="no-domains">No blocks recorded</div>'}
                </div>
            </div>
            
            <div class="graph-section">
                <div class="section-title">[Block Rate Graph - Live Time Series]</div>
                <div class="graph">{rate_graph}</div>
            </div>
        </div>
    </div>
</body>
</html>
"""

# Start the dashboard server on a specified port.
def start_dashboard(port=8080):
    """Start the dashboard server"""
    global DASHBOARD_START_TIME
    DASHBOARD_START_TIME = time.time()  # Record start time
    
    try:
        with socketserver.TCPServer(("", port), DashboardHandler) as httpd:
            print(f"eBAF Dashboard server running on http://localhost:{port}")
            print("Press Ctrl+C to stop...")
            httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nDashboard server stopped.")
    except OSError as e:
        if e.errno == 98:  # Address already in use
            print(f"Error: Port {port} is already in use")
            print("Another instance might be running or another service is using this port")
        else:
            print(f"Error starting server: {e}")

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