#!/bin/bash

# Video Generation API Test Script
# Base URL
BASE_URL="http://localhost:4000/api/v3"

echo "🧪 Testing Video Generation API Endpoints"
echo "========================================="

# Test 1: List Clients
echo -e "\n1️⃣ Testing GET /clients..."
curl -s "$BASE_URL/clients" | jq '.meta'

# Test 2: List Campaigns
echo -e "\n2️⃣ Testing GET /campaigns..."
curl -s "$BASE_URL/campaigns" | jq '.meta'

# Test 3: Get existing campaigns from DB
echo -e "\n3️⃣ Testing GET /campaigns (should have existing data)..."
CAMPAIGNS=$(curl -s "$BASE_URL/campaigns")
echo "$CAMPAIGNS" | jq '.data[] | {id, name, client_id}'

# Test 4: Get campaign assets (using ID 1 if exists)
echo -e "\n4️⃣ Testing GET /campaigns/1/assets..."
ASSETS=$(curl -s "$BASE_URL/campaigns/1/assets")
if [[ $(echo "$ASSETS" | jq -r '.error') == "null" ]]; then
  echo "Assets found: $(echo "$ASSETS" | jq '.meta.total')"
  echo "$ASSETS" | jq '.data[0:3] | .[] | {id, filename, type}'
else
  echo "Campaign not found or has no assets"
fi

# Test 5: Create a test client
echo -e "\n5️⃣ Testing POST /clients (create test client)..."
CLIENT=$(curl -s -X POST "$BASE_URL/clients" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Test Client",
    "email": "test@example.com",
    "metadata": {"industry": "real_estate"}
  }')
CLIENT_ID=$(echo "$CLIENT" | jq -r '.data.id')
echo "Created client ID: $CLIENT_ID"

# Test 6: Create a test campaign
echo -e "\n6️⃣ Testing POST /campaigns (create test campaign)..."
CAMPAIGN=$(curl -s -X POST "$BASE_URL/campaigns" \
  -H "Content-Type: application/json" \
  -d "{
    \"name\": \"Test Campaign $(date +%s)\",
    \"client_id\": $CLIENT_ID,
    \"status\": \"active\",
    \"metadata\": {\"style\": \"modern\", \"music_genre\": \"upbeat\"}
  }")
CAMPAIGN_ID=$(echo "$CAMPAIGN" | jq -r '.data.id')
echo "Created campaign ID: $CAMPAIGN_ID"

# Test 7: Create job from existing campaign (if has assets)
echo -e "\n7️⃣ Testing POST /campaigns/:id/create-job..."
# Try with campaign 1 first (which should have assets from migration)
JOB=$(curl -s -X POST "$BASE_URL/campaigns/1/create-job" \
  -H "Content-Type: application/json" \
  -d '{
    "style": "modern",
    "music_genre": "upbeat",
    "duration_seconds": 30
  }')

if [[ $(echo "$JOB" | jq -r '.error') == "null" ]]; then
  JOB_ID=$(echo "$JOB" | jq -r '.data.id')
  echo "✅ Created job ID: $JOB_ID from campaign"
  echo "   Asset count: $(echo "$JOB" | jq -r '.data.asset_count')"
  echo "   Status: $(echo "$JOB" | jq -r '.data.status')"

  # Test 8: Get job status
  echo -e "\n8️⃣ Testing GET /jobs/$JOB_ID..."
  curl -s "$BASE_URL/jobs/$JOB_ID" | jq '{job_id, type, status, progress_percentage}'

  # Test 9: Approve the job
  echo -e "\n9️⃣ Testing POST /jobs/$JOB_ID/approve..."
  APPROVAL=$(curl -s -X POST "$BASE_URL/jobs/$JOB_ID/approve")
  echo "$APPROVAL" | jq .
else
  echo "❌ Could not create job - campaign may have no assets"
  echo "$JOB" | jq .
fi

# Test 10: List all routes
echo -e "\n🗺️ All available routes:"
curl -s "http://localhost:4000/api/openapi" | jq -r '.routes[] | "\(.methods | join(", ")) \(.path)"' | sort

echo -e "\n✅ API test complete!"