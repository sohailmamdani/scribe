# Plan: Build Web UI for Claude Code Custom Workflows

## What We'll Build

A simple web application that lets you trigger Claude Code workflows (like creating Jira stories) through a web interface.

## Architecture

**Frontend:**
- Simple HTML/React page with text input
- Buttons for common workflows
- Display area for results

**Backend:**
- Python FastAPI server
- Spawns Claude Code CLI as subprocess in `--print` mode
- Leverages your existing Atlassian MCP configuration

## Implementation Steps

1. **Create FastAPI backend** (`backend/main.py`)
   - `/api/execute` endpoint that takes prompts
   - Subprocess management for Claude Code CLI
   - JSON response formatting

2. **Create simple web frontend** (`frontend/index.html`)
   - Text input for custom prompts
   - Quick action buttons (e.g., "Create Jira Story")
   - Results display area

3. **Configuration**
   - Environment variable for Claude Code path
   - Optional: User session management
   - Optional: Request logging

## File Structure

```
claude-web/
├── backend/
│   ├── main.py           # FastAPI server
│   ├── claude_client.py  # Claude Code CLI wrapper
│   └── requirements.txt  # Dependencies
├── frontend/
│   └── index.html        # Simple UI
└── README.md             # Setup instructions
```

## Example Usage

**Web UI text input:**
```
Use atlassian to create a new story in the SETI space
with summary "Complete this task" and estimate of 30 minutes
```

**Backend invokes:**
```bash
claude --print --output-format json "Use atlassian to create..."
```

**Result displayed in web UI.**

## Benefits

- ✅ Reuses your existing Claude Code + Atlassian MCP setup
- ✅ No need to reconfigure API keys or MCP servers
- ✅ Simple architecture, quick to build
- ✅ Can extend with more workflows later

## Recommended Technology Stack

### Backend: Python + FastAPI

**Why Python:**
- Simple subprocess management
- FastAPI is fast and modern
- Great async support
- Easy to extend

**Core Dependencies:**
```
fastapi
uvicorn
python-multipart
```

### Frontend: Simple HTML + Vanilla JavaScript

**Why Simple HTML:**
- No build step needed
- Easy to customize
- Can upgrade to React later if needed
- Fast to prototype

**Alternative:** React/Next.js if you want a more polished UI

## Implementation Details

### Backend Code Structure

```python
# backend/main.py
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from claude_client import ClaudeClient

app = FastAPI()
claude = ClaudeClient()

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # Configure for production
    allow_methods=["*"],
    allow_headers=["*"],
)

@app.post("/api/execute")
async def execute_prompt(request: dict):
    prompt = request.get("prompt")
    result = await claude.execute(prompt)
    return result
```

```python
# backend/claude_client.py
import subprocess
import json
import asyncio

class ClaudeClient:
    def __init__(self, claude_path="claude"):
        self.claude_path = claude_path

    async def execute(self, prompt: str):
        process = await asyncio.create_subprocess_exec(
            self.claude_path,
            "--print",
            "--output-format", "json",
            prompt,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE
        )

        stdout, stderr = await process.communicate()

        if process.returncode == 0:
            return json.loads(stdout.decode())
        else:
            raise Exception(f"Claude error: {stderr.decode()}")
```

### Frontend Code Structure

```html
<!-- frontend/index.html -->
<!DOCTYPE html>
<html>
<head>
    <title>Claude Code Web UI</title>
    <style>
        body {
            font-family: system-ui;
            max-width: 800px;
            margin: 40px auto;
            padding: 20px;
        }
        #prompt {
            width: 100%;
            padding: 12px;
            font-size: 16px;
            border: 2px solid #ddd;
            border-radius: 8px;
        }
        .quick-actions {
            margin: 20px 0;
        }
        .quick-actions button {
            padding: 10px 20px;
            margin: 5px;
            border: none;
            background: #007AFF;
            color: white;
            border-radius: 6px;
            cursor: pointer;
        }
        #result {
            margin-top: 20px;
            padding: 20px;
            background: #f5f5f5;
            border-radius: 8px;
            white-space: pre-wrap;
        }
    </style>
</head>
<body>
    <h1>Claude Code Web UI</h1>

    <textarea
        id="prompt"
        rows="4"
        placeholder="Enter your command..."
    ></textarea>

    <div class="quick-actions">
        <button onclick="executePrompt()">Execute</button>
        <button onclick="useTemplate('jira-story')">Create Jira Story</button>
        <button onclick="useTemplate('jira-estimate')">Add Estimate</button>
    </div>

    <div id="result"></div>

    <script>
        async function executePrompt() {
            const prompt = document.getElementById('prompt').value;
            const resultDiv = document.getElementById('result');

            resultDiv.textContent = 'Processing...';

            try {
                const response = await fetch('http://localhost:8000/api/execute', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ prompt })
                });

                const data = await response.json();
                resultDiv.textContent = JSON.stringify(data, null, 2);
            } catch (error) {
                resultDiv.textContent = 'Error: ' + error.message;
            }
        }

        function useTemplate(template) {
            const templates = {
                'jira-story': 'Use atlassian to create a new story in the SETI space with summary "[SUMMARY]" and estimate of [MINUTES] minutes',
                'jira-estimate': 'Use atlassian to update story [STORY-ID] with estimate of [MINUTES] minutes'
            };

            document.getElementById('prompt').value = templates[template];
        }
    </script>
</body>
</html>
```

## Security Considerations

### For Production Deployment:

1. **Authentication**
   - Add user authentication (JWT, session cookies)
   - Protect API endpoints

2. **CORS Configuration**
   - Restrict `allow_origins` to your frontend domain
   - Don't use `["*"]` in production

3. **Rate Limiting**
   - Implement per-user rate limits
   - Prevent abuse of Claude API

4. **Input Validation**
   - Sanitize user inputs
   - Validate prompt length
   - Block malicious patterns

5. **API Key Protection**
   - Claude API key stays server-side
   - Never expose in frontend
   - Use environment variables

6. **Sandboxing (if using Bash tool)**
   - Run Claude Code in Docker container
   - Restrict file system access
   - Use `--allowed-tools` flag

## Setup Instructions

### Backend Setup

```bash
# Create project directory
mkdir claude-web
cd claude-web
mkdir backend frontend

# Set up Python environment
cd backend
python3 -m venv venv
source venv/bin/activate

# Install dependencies
pip install fastapi uvicorn python-multipart

# Create files
touch main.py claude_client.py

# Run server
uvicorn main:app --reload --port 8000
```

### Frontend Setup

```bash
# Just create the HTML file
cd ../frontend
touch index.html

# Open in browser or serve with simple HTTP server
python3 -m http.server 3000
```

### Configuration

**Environment Variables:**
```bash
# .env file
CLAUDE_PATH=claude  # or /usr/local/bin/claude
API_HOST=localhost
API_PORT=8000
```

## Testing the System

### Test 1: Simple Prompt
```
Prompt: "What is 2 + 2?"
Expected: Claude responds with "4"
```

### Test 2: Atlassian MCP (Your Use Case)
```
Prompt: "Use atlassian to create a new story in the SETI space with summary 'Test story' and estimate of 30 minutes"
Expected: Jira story created, API returns story URL/ID
```

### Test 3: Error Handling
```
Prompt: (invalid command)
Expected: Graceful error message displayed
```

## Extending the System

### Add More Workflow Buttons

```javascript
const workflows = {
    'create-bug': 'Use atlassian to create a bug in SETI space with summary "[SUMMARY]"',
    'assign-story': 'Use atlassian to assign story [ID] to [USER]',
    'move-to-progress': 'Use atlassian to move story [ID] to In Progress',
    'add-comment': 'Use atlassian to add comment "[COMMENT]" to story [ID]'
};
```

### Add Response Formatting

```python
# backend/main.py
@app.post("/api/execute")
async def execute_prompt(request: dict):
    result = await claude.execute(request["prompt"])

    # Format for better UI display
    return {
        "success": True,
        "result": result.get("result"),
        "cost": result.get("total_cost_usd"),
        "usage": result.get("usage")
    }
```

### Add Session History

```python
# Store conversation history per user
from collections import defaultdict

sessions = defaultdict(list)

@app.post("/api/execute")
async def execute_prompt(request: dict):
    user_id = request.get("user_id", "default")
    prompt = request["prompt"]

    # Add to history
    sessions[user_id].append({"role": "user", "content": prompt})

    result = await claude.execute(prompt)

    sessions[user_id].append({"role": "assistant", "content": result["result"]})

    return result
```

## Deployment Options

### Local Development
- Backend: `uvicorn main:app --reload --port 8000`
- Frontend: `python3 -m http.server 3000`
- Access at: `http://localhost:3000`

### Production Options

**Option 1: Simple VPS (DigitalOcean, Linode)**
```bash
# Deploy with systemd service
sudo systemctl enable claude-web
sudo systemctl start claude-web
```

**Option 2: Docker**
```dockerfile
FROM python:3.11
WORKDIR /app
COPY backend/ .
RUN pip install -r requirements.txt
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
```

**Option 3: Serverless (AWS Lambda + API Gateway)**
- Use Mangum adapter for FastAPI
- Deploy frontend to S3 + CloudFront
- More complex but highly scalable

## Cost Estimation

### Claude API Costs
Based on your usage pattern:
- Input: ~50 tokens per request
- Output: ~200 tokens per request
- Model: Claude Sonnet 4.5
- Cost per request: ~$0.0002-$0.0005
- 1000 requests/day: ~$0.20-$0.50/day

### Infrastructure Costs
- **Free tier**: Run locally or on personal server ($0)
- **VPS**: $5-10/month (DigitalOcean, Linode)
- **AWS**: Variable, likely $10-20/month for low traffic

## Next Steps

1. **Prototype** (1-2 hours)
   - Create basic backend and frontend
   - Test with simple prompts

2. **Integrate Atlassian** (30 minutes)
   - Test with your existing MCP configuration
   - Verify Jira story creation works

3. **Polish UI** (1-2 hours)
   - Add workflow buttons
   - Improve styling
   - Add error handling

4. **Deploy** (1 hour)
   - Choose deployment option
   - Configure production settings
   - Test end-to-end

Total estimated time: **4-6 hours** for fully working system

## Conclusion

This architecture gives you:
- ✅ Web interface for Claude Code
- ✅ Reuses all your existing MCP servers (Atlassian, etc.)
- ✅ Simple to build and extend
- ✅ No need to reimplement skills/commands
- ✅ Production-ready with proper security

Perfect for creating custom business workflows with Claude Code!
