# Cloud Run Warm-Up Evaluation

**Date:** 2026-04-02  
**Status:** EVALUATED - Warm-up is NOT cost-effective for daily jobs  
**Decision:** Skip warm-up implementation

## Executive Summary

After analyzing the cost-benefit of Cloud Run warm-up strategies for se-daily-agent-job and se-explorer-agent-job, we conclude that **warm-up is unnecessary and not cost-effective**. The negligible cold-start overhead (1-3 seconds for Rust binaries) is insignificant for jobs running once daily.

## Current Deployment

### Jobs
- **se-daily-agent-job**: Runs once daily (~0.06-0.15 executions/hour)
- **se-explorer-agent-job**: Runs once weekly (~0.006 executions/hour)
- Both deployed via `.github/workflows/deploy.yml`
- Task timeout: 5m (daily), 30m (explorer)
- Cloud Run Jobs (not Services) - no min-instances capability

### Container Characteristics
- **Base:** Debian bookworm-slim (minimal footprint)
- **Binary:** Rust static binary (~40-50MB uncompressed)
- **Runtime Dependencies:** ca-certificates, libssl3
- **Startup Pattern:** Single-threaded, async Rust with tokio
- **No warm-up dependencies:** No heavy initialization, pre-fetching, or caching on startup

## Cost Analysis

### Cloud Run Jobs Pricing (us-central1)
- **vCPU:** $0.00002400/vCPU-second
- **Memory:** $0.00000250/GiB-second
- **Jobs don't support min-instances** (that's a Services feature only)
- Cold start overhead: ~2-3 seconds for typical Rust job startup

### Warm-Up Strategies (Evaluated)

#### Strategy 1: Cloud Scheduler Ping (Would NOT Work)
**Concept:** Pre-warm with a scheduled Cloud Scheduler ping  
**Problem:** Cloud Run **Jobs** cannot stay warm like Services
- Jobs execute once and complete
- Cannot maintain persistent warm state
- A pre-ping would just trigger an extra job execution
- **Cost:** Extra ~1-2 minutes of execution time daily = **+$0.22-0.44/month**
- **Benefit:** Negligible (saves 1-3 seconds per daily job run)
- **ROI:** Negative - costs more than it saves

#### Strategy 2: Cloud Run Service with Scheduler (Alternative, but overkill)
**Concept:** Convert from Jobs to Services with min-instances=1  
**Cost:** ~$10-15/month for always-running instance
- Minimum instance: ~2-4 vCPU, 512MB-2GB memory
- 24/7 minimum cost per instance
**Benefit:** Instant execution, no cold start  
**Analysis:** Not justified for a once-daily job
- Daily job execution: ~30-60 seconds
- If always-warm: ~2,592,000 seconds/month (always running)
- Service model increases cost 40,000x for negligible benefit

### Cold Start Impact Analysis

**Typical Rust Binary Cold Start Timeline:**
1. Container start: ~100ms
2. Binary load & initialization: ~500-1,000ms
3. Async runtime (tokio) bootstrap: ~200-400ms
4. First API call: ~1,200-2,400ms total elapsed

**For Daily Job (365 executions/year):**
- Cold start overhead: ~2-3 seconds per execution
- Annual cost of 2-second cold start: 730 seconds × $0.00002400/vCPU-second ≈ **$0.018/year**
- This is negligible even before considering caching improvements

### Cost Threshold

Task specification: **"Expected cost increase > $10 USD/month needs explicit confirmation"**

- Warm-up via Cloud Scheduler ping: **-$0.22-0.44/month** (negative ROI)
- Service with min-instances: **$10-15/month** (would require approval, not justified)
- Current state (no warm-up): **Optimal**

## Technical Findings

### Why Cold Start is Negligible for Jobs
1. **Jobs run infrequently** - Daily/weekly frequency means the ~2-second cold start is amortized over hours
2. **No critical path dependency** - Jobs already involve 1-5 minutes of HTTP I/O and Gemini API calls
3. **Containerization overhead is minimal** - Debian slim + Rust binary has very fast startup
4. **No pre-warming prerequisites** - Jobs don't maintain state between runs; no cache to pre-populate

### Why Warm-Up Strategies Don't Apply to Jobs
- **Cloud Scheduler can only trigger jobs, not keep them warm**
- Jobs complete and deallocate immediately
- Maintaining persistent warm state requires Services, not Jobs
- Services would increase monthly cost 40x+ for <1% performance gain

## Recommendation

### ✅ DECISION: Skip warm-up implementation

**Rationale:**
1. Cold start is 1-3 seconds for a job that already takes 2-5 minutes to execute
2. Daily/weekly frequency makes warm-up strategies either impossible (Jobs) or prohibitively expensive (Services)
3. No cost savings or meaningful performance improvement
4. No change needed to deployment workflow

### Documentation
- Deployment configuration in `.github/workflows/deploy.yml` is optimal for current requirements
- No code changes required
- No Cloud Scheduler setup needed
- Focus efforts on optimizing actual job execution logic instead

## Monitoring

If job cold start becomes a concern in the future:

1. **Check actual metrics:**
   ```bash
   gcloud logging read 'resource.type="cloud_run_job" AND resource.labels.job_name="se-daily-agent-job"' --limit=10 --format=json | jq '.[] | {timestamp: .timestamp, duration: .duration}'
   ```

2. **Only revisit warm-up if:**
   - Cold start exceeds 30+ seconds (currently ~2-3s)
   - Job execution frequency increases to hourly or higher
   - Cost analysis shows >$10/month savings possible

## References

- GCP Cloud Run Pricing: https://cloud.google.com/run/pricing
- Cloud Run Jobs documentation: https://cloud.google.com/run/docs/quickstarts/jobs/create-execute
- Deployment configuration: `.github/workflows/deploy.yml`
- Daily agent runtime: `apps/daily-agent/README.md`
