#!/bin/bash
# Setup observability infrastructure for Eng Pulse
# Creates: notification channels, alert policies, and dashboard

set -e

PROJECT_ID="${PROJECT_ID:-tsvet01}"
REGION="${REGION:-us-central1}"
NOTIFICATION_EMAIL="${NOTIFICATION_EMAIL:-}"

echo "Setting up observability for project: $PROJECT_ID"

# Ensure we're using the right project
gcloud config set project "$PROJECT_ID" --quiet

# Enable required APIs
echo "Enabling monitoring APIs..."
gcloud services enable monitoring.googleapis.com --quiet

# ============================================
# 1. Create Email Notification Channel
# ============================================
create_notification_channel() {
    if [ -z "$NOTIFICATION_EMAIL" ]; then
        echo "NOTIFICATION_EMAIL not set, skipping notification channel"
        echo "Set it with: export NOTIFICATION_EMAIL=your@email.com"
        return
    fi

    echo "Creating email notification channel..."

    # Check if channel already exists
    EXISTING=$(gcloud alpha monitoring channels list \
        --filter="type=email AND labels.email_address=$NOTIFICATION_EMAIL" \
        --format="value(name)" 2>/dev/null || true)

    if [ -n "$EXISTING" ]; then
        echo "Notification channel already exists: $EXISTING"
        CHANNEL_ID="$EXISTING"
    else
        CHANNEL_ID=$(gcloud alpha monitoring channels create \
            --display-name="Eng Pulse Alerts" \
            --type=email \
            --channel-labels=email_address="$NOTIFICATION_EMAIL" \
            --format="value(name)")
        echo "Created notification channel: $CHANNEL_ID"
    fi

    export NOTIFICATION_CHANNEL="$CHANNEL_ID"
}

# ============================================
# 2. Create Alert Policies
# ============================================
create_alert_policies() {
    echo "Creating alert policies..."

    # Get notification channel for alerts
    CHANNELS_FLAG=""
    if [ -n "$NOTIFICATION_CHANNEL" ]; then
        CHANNELS_FLAG="--notification-channels=$NOTIFICATION_CHANNEL"
    fi

    # Alert: Daily Agent Job Failure
    echo "Creating daily-agent failure alert..."
    cat > /tmp/daily-agent-alert.json << 'EOF'
{
  "displayName": "Daily Agent Job Failed",
  "documentation": {
    "content": "The se-daily-agent-job Cloud Run job has failed. Check logs for details.",
    "mimeType": "text/markdown"
  },
  "conditions": [
    {
      "displayName": "Job execution failed",
      "conditionThreshold": {
        "filter": "resource.type=\"cloud_run_job\" AND resource.labels.job_name=\"se-daily-agent-job\" AND metric.type=\"run.googleapis.com/job/completed_execution_count\" AND metric.labels.result=\"failed\"",
        "aggregations": [
          {
            "alignmentPeriod": "300s",
            "perSeriesAligner": "ALIGN_SUM"
          }
        ],
        "comparison": "COMPARISON_GT",
        "thresholdValue": 0,
        "duration": "0s",
        "trigger": {
          "count": 1
        }
      }
    }
  ],
  "combiner": "OR",
  "enabled": true,
  "alertStrategy": {
    "autoClose": "604800s"
  }
}
EOF

    # Check if alert already exists
    EXISTING_ALERT=$(gcloud alpha monitoring policies list \
        --filter="displayName='Daily Agent Job Failed'" \
        --format="value(name)" 2>/dev/null | head -1 || true)

    if [ -z "$EXISTING_ALERT" ]; then
        gcloud alpha monitoring policies create \
            --policy-from-file=/tmp/daily-agent-alert.json \
            $CHANNELS_FLAG 2>/dev/null || echo "Note: Alert creation requires additional permissions"
    else
        echo "Daily agent alert already exists"
    fi

    # Alert: Explorer Agent Job Failure
    echo "Creating explorer-agent failure alert..."
    cat > /tmp/explorer-agent-alert.json << 'EOF'
{
  "displayName": "Explorer Agent Job Failed",
  "documentation": {
    "content": "The se-explorer-agent-job Cloud Run job has failed. Check logs for details.",
    "mimeType": "text/markdown"
  },
  "conditions": [
    {
      "displayName": "Job execution failed",
      "conditionThreshold": {
        "filter": "resource.type=\"cloud_run_job\" AND resource.labels.job_name=\"se-explorer-agent-job\" AND metric.type=\"run.googleapis.com/job/completed_execution_count\" AND metric.labels.result=\"failed\"",
        "aggregations": [
          {
            "alignmentPeriod": "300s",
            "perSeriesAligner": "ALIGN_SUM"
          }
        ],
        "comparison": "COMPARISON_GT",
        "thresholdValue": 0,
        "duration": "0s",
        "trigger": {
          "count": 1
        }
      }
    }
  ],
  "combiner": "OR",
  "enabled": true,
  "alertStrategy": {
    "autoClose": "604800s"
  }
}
EOF

    EXISTING_ALERT=$(gcloud alpha monitoring policies list \
        --filter="displayName='Explorer Agent Job Failed'" \
        --format="value(name)" 2>/dev/null | head -1 || true)

    if [ -z "$EXISTING_ALERT" ]; then
        gcloud alpha monitoring policies create \
            --policy-from-file=/tmp/explorer-agent-alert.json \
            $CHANNELS_FLAG 2>/dev/null || echo "Note: Alert creation requires additional permissions"
    else
        echo "Explorer agent alert already exists"
    fi

    # Alert: Notifier Function Errors
    echo "Creating notifier function error alert..."
    cat > /tmp/notifier-alert.json << 'EOF'
{
  "displayName": "Notifier Function Errors",
  "documentation": {
    "content": "The se-daily-notifier Cloud Function is experiencing errors. Check logs for details.",
    "mimeType": "text/markdown"
  },
  "conditions": [
    {
      "displayName": "Function errors > 0",
      "conditionThreshold": {
        "filter": "resource.type=\"cloud_function\" AND resource.labels.function_name=\"se-daily-notifier\" AND metric.type=\"cloudfunctions.googleapis.com/function/execution_count\" AND metric.labels.status!=\"ok\"",
        "aggregations": [
          {
            "alignmentPeriod": "300s",
            "perSeriesAligner": "ALIGN_SUM"
          }
        ],
        "comparison": "COMPARISON_GT",
        "thresholdValue": 0,
        "duration": "0s",
        "trigger": {
          "count": 1
        }
      }
    }
  ],
  "combiner": "OR",
  "enabled": true,
  "alertStrategy": {
    "autoClose": "604800s"
  }
}
EOF

    EXISTING_ALERT=$(gcloud alpha monitoring policies list \
        --filter="displayName='Notifier Function Errors'" \
        --format="value(name)" 2>/dev/null | head -1 || true)

    if [ -z "$EXISTING_ALERT" ]; then
        gcloud alpha monitoring policies create \
            --policy-from-file=/tmp/notifier-alert.json \
            $CHANNELS_FLAG 2>/dev/null || echo "Note: Alert creation requires additional permissions"
    else
        echo "Notifier alert already exists"
    fi

    # Alert: No summary generated in 25 hours (missed daily run)
    #
    # Matches the live MQL-based policy already running in GCP. A
    # conditionAbsent duration this long (>~24h) is rejected by Cloud
    # Monitoring at policy-creation time, so absence is expressed inside the
    # MQL query itself via `absent_for` instead.
    echo "Creating missing summary alert..."
    cat > /tmp/missing-summary-alert.json << 'EOF'
{
  "displayName": "No Summary Generated (25h)",
  "documentation": {
    "content": "No new summary has been generated in 25 hours. The daily agent may not be running.",
    "mimeType": "text/markdown"
  },
  "conditions": [
    {
      "displayName": "No successful job executions",
      "conditionMonitoringQueryLanguage": {
        "query": "fetch cloud_run_job :: run.googleapis.com/job/completed_execution_count | filter resource.job_name == 'se-daily-agent-job' && metric.result == 'succeeded' | absent_for 90000s",
        "duration": "0s",
        "trigger": {
          "count": 1
        }
      }
    }
  ],
  "combiner": "OR",
  "enabled": true,
  "alertStrategy": {
    "autoClose": "604800s"
  }
}
EOF

    EXISTING_ALERT=$(gcloud alpha monitoring policies list \
        --filter="displayName='No Summary Generated (25h)'" \
        --format="value(name)" 2>/dev/null | head -1 || true)

    if [ -z "$EXISTING_ALERT" ]; then
        gcloud alpha monitoring policies create \
            --policy-from-file=/tmp/missing-summary-alert.json \
            $CHANNELS_FLAG 2>/dev/null || echo "Note: Alert creation requires additional permissions"
    else
        echo "Missing summary alert already exists"
    fi

    # Alert: Agent Fatal Error (log-based, includes the error message)
    #
    # The metric-based "Job Failed" alerts above tell you THAT a job failed but
    # not WHY. This log-based alert matches the fatal "Error: ..." line the agents
    # print on crash and embeds the actual error text in the notification (e.g.
    # "Claude API returned 400 ... temperature is deprecated"), so triage doesn't
    # require opening Cloud Logging.
    echo "Creating agent fatal-error (detailed) alert..."
    cat > /tmp/agent-error-alert.json << 'EOF'
{
  "displayName": "Agent Fatal Error (with details)",
  "documentation": {
    "content": "Agent **${log.extracted_label.job_name}** logged a fatal error:\n\n    ${log.extracted_label.error_detail}\n\nThe daily/explorer run most likely failed. Open Cloud Logging for the full stack and surrounding context:\nhttps://console.cloud.google.com/logs/query?project=__PROJECT_ID__",
    "mimeType": "text/markdown"
  },
  "conditions": [
    {
      "displayName": "Agent logged a fatal error",
      "conditionMatchedLog": {
        "filter": "resource.type=\"cloud_run_job\" AND (resource.labels.job_name=\"se-daily-agent-job\" OR resource.labels.job_name=\"se-explorer-agent-job\") AND textPayload:\"Error:\"",
        "labelExtractors": {
          "error_detail": "EXTRACT(textPayload)",
          "job_name": "EXTRACT(resource.labels.job_name)"
        }
      }
    }
  ],
  "combiner": "OR",
  "enabled": true,
  "alertStrategy": {
    "notificationRateLimit": {
      "period": "300s"
    },
    "autoClose": "604800s"
  }
}
EOF

    # Quoted heredoc preserves the ${log.extracted_label.*} Monitoring template
    # vars verbatim; expand only our own project-id placeholder.
    sed -i.bak "s|__PROJECT_ID__|$PROJECT_ID|g" /tmp/agent-error-alert.json && rm -f /tmp/agent-error-alert.json.bak

    EXISTING_ALERT=$(gcloud alpha monitoring policies list \
        --filter="displayName='Agent Fatal Error (with details)'" \
        --format="value(name)" 2>/dev/null | head -1 || true)

    if [ -z "$EXISTING_ALERT" ]; then
        gcloud alpha monitoring policies create \
            --policy-from-file=/tmp/agent-error-alert.json \
            $CHANNELS_FLAG 2>/dev/null || echo "Note: Alert creation requires additional permissions"
    else
        echo "Agent fatal-error alert already exists"
    fi

    rm -f /tmp/daily-agent-alert.json /tmp/explorer-agent-alert.json \
          /tmp/notifier-alert.json /tmp/missing-summary-alert.json \
          /tmp/agent-error-alert.json
}

# ============================================
# 3. Create Dashboard
# ============================================
create_dashboard() {
    echo "Creating monitoring dashboard..."

    cat > /tmp/dashboard.json << EOF
{
  "displayName": "Eng Pulse Overview",
  "gridLayout": {
    "columns": "2",
    "widgets": [
      {
        "title": "Daily Agent Executions",
        "xyChart": {
          "dataSets": [
            {
              "timeSeriesQuery": {
                "timeSeriesFilter": {
                  "filter": "resource.type=\"cloud_run_job\" AND resource.labels.job_name=\"se-daily-agent-job\" AND metric.type=\"run.googleapis.com/job/completed_execution_count\"",
                  "aggregation": {
                    "alignmentPeriod": "3600s",
                    "perSeriesAligner": "ALIGN_SUM",
                    "groupByFields": ["metric.labels.result"]
                  }
                }
              },
              "plotType": "STACKED_BAR"
            }
          ],
          "timeshiftDuration": "0s",
          "yAxis": {
            "scale": "LINEAR"
          }
        }
      },
      {
        "title": "Explorer Agent Executions",
        "xyChart": {
          "dataSets": [
            {
              "timeSeriesQuery": {
                "timeSeriesFilter": {
                  "filter": "resource.type=\"cloud_run_job\" AND resource.labels.job_name=\"se-explorer-agent-job\" AND metric.type=\"run.googleapis.com/job/completed_execution_count\"",
                  "aggregation": {
                    "alignmentPeriod": "3600s",
                    "perSeriesAligner": "ALIGN_SUM",
                    "groupByFields": ["metric.labels.result"]
                  }
                }
              },
              "plotType": "STACKED_BAR"
            }
          ],
          "timeshiftDuration": "0s",
          "yAxis": {
            "scale": "LINEAR"
          }
        }
      },
      {
        "title": "Notifier Function Invocations",
        "xyChart": {
          "dataSets": [
            {
              "timeSeriesQuery": {
                "timeSeriesFilter": {
                  "filter": "resource.type=\"cloud_function\" AND resource.labels.function_name=\"se-daily-notifier\" AND metric.type=\"cloudfunctions.googleapis.com/function/execution_count\"",
                  "aggregation": {
                    "alignmentPeriod": "3600s",
                    "perSeriesAligner": "ALIGN_SUM",
                    "groupByFields": ["metric.labels.status"]
                  }
                }
              },
              "plotType": "STACKED_BAR"
            }
          ],
          "timeshiftDuration": "0s",
          "yAxis": {
            "scale": "LINEAR"
          }
        }
      },
      {
        "title": "Job Execution Duration",
        "xyChart": {
          "dataSets": [
            {
              "timeSeriesQuery": {
                "timeSeriesFilter": {
                  "filter": "resource.type=\"cloud_run_job\" AND metric.type=\"run.googleapis.com/job/completed_task_attempt_count\"",
                  "aggregation": {
                    "alignmentPeriod": "3600s",
                    "perSeriesAligner": "ALIGN_SUM",
                    "groupByFields": ["resource.labels.job_name"]
                  }
                }
              },
              "plotType": "LINE"
            }
          ],
          "timeshiftDuration": "0s",
          "yAxis": {
            "scale": "LINEAR"
          }
        }
      },
      {
        "title": "Error Logs (Last 24h)",
        "logsPanel": {
          "filter": "resource.type=\"cloud_run_job\" OR resource.type=\"cloud_function\"\nseverity>=ERROR",
          "resourceNames": ["projects/$PROJECT_ID"]
        }
      },
      {
        "title": "GCS Storage Operations",
        "xyChart": {
          "dataSets": [
            {
              "timeSeriesQuery": {
                "timeSeriesFilter": {
                  "filter": "resource.type=\"gcs_bucket\" AND resource.labels.bucket_name=\"${PROJECT_ID}-agent-brain\" AND metric.type=\"storage.googleapis.com/api/request_count\"",
                  "aggregation": {
                    "alignmentPeriod": "3600s",
                    "perSeriesAligner": "ALIGN_SUM",
                    "groupByFields": ["metric.labels.method"]
                  }
                }
              },
              "plotType": "STACKED_AREA"
            }
          ],
          "timeshiftDuration": "0s",
          "yAxis": {
            "scale": "LINEAR"
          }
        }
      }
    ]
  }
}
EOF

    # Check if dashboard already exists
    EXISTING_DASHBOARD=$(gcloud monitoring dashboards list \
        --filter="displayName='Eng Pulse Overview'" \
        --format="value(name)" 2>/dev/null | head -1 || true)

    if [ -z "$EXISTING_DASHBOARD" ]; then
        gcloud monitoring dashboards create --config-from-file=/tmp/dashboard.json
        echo "Dashboard created successfully"
    else
        echo "Dashboard already exists, updating..."
        DASHBOARD_ID=$(echo "$EXISTING_DASHBOARD" | rev | cut -d'/' -f1 | rev)
        gcloud monitoring dashboards update "$DASHBOARD_ID" --config-from-file=/tmp/dashboard.json 2>/dev/null || \
            echo "Note: Dashboard update may require manual refresh"
    fi

    rm -f /tmp/dashboard.json
}

# ============================================
# Main
# ============================================
echo ""
echo "============================================"
echo "Setting up Eng Pulse Observability"
echo "============================================"
echo ""

create_notification_channel
create_alert_policies
create_dashboard

echo ""
echo "============================================"
echo "Setup Complete!"
echo "============================================"
echo ""
echo "View dashboard:"
echo "  https://console.cloud.google.com/monitoring/dashboards?project=$PROJECT_ID"
echo ""
echo "View alerts:"
echo "  https://console.cloud.google.com/monitoring/alerting?project=$PROJECT_ID"
echo ""
echo "View logs:"
echo "  https://console.cloud.google.com/logs/query?project=$PROJECT_ID"
echo ""
