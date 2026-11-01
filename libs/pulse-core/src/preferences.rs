use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Topic {
    CpuPerformance,
    Data,
    Platform,
    Reliability,
    Security,
    AiMl,
    EngineeringLeadership,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TopicDefinition {
    pub id: Topic,
    pub name: String,
    pub description: String,
}

pub fn topic_catalog() -> Vec<TopicDefinition> {
    [
        (
            Topic::CpuPerformance,
            "CPU & Performance",
            "CPU, high load, latency and optimisation",
        ),
        (
            Topic::Data,
            "Data",
            "Databases, storage, streaming and data engineering",
        ),
        (
            Topic::Platform,
            "Platform",
            "Infrastructure, distributed systems and developer platforms",
        ),
        (
            Topic::Reliability,
            "Reliability & Incidents",
            "Crashes, outages, debugging and postmortems",
        ),
        (
            Topic::Security,
            "Security",
            "Vulnerabilities, exploits and defensive engineering",
        ),
        (
            Topic::AiMl,
            "AI & ML",
            "Models, machine learning systems and applied AI",
        ),
        (
            Topic::EngineeringLeadership,
            "Engineering Leadership",
            "Technical strategy, teams and engineering practice",
        ),
    ]
    .into_iter()
    .map(|(id, name, description)| TopicDefinition {
        id,
        name: name.into(),
        description: description.into(),
    })
    .collect()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TechnicalDepth {
    Introductory,
    Intermediate,
    Advanced,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PreferenceChoices {
    pub interests: Vec<Topic>,
    pub depth_by_topic: BTreeMap<Topic, TechnicalDepth>,
    pub excluded_topics: Vec<Topic>,
}

impl PreferenceChoices {
    pub fn is_valid(&self) -> bool {
        let interests: BTreeSet<_> = self.interests.iter().collect();
        let excluded: BTreeSet<_> = self.excluded_topics.iter().collect();
        interests.len() == self.interests.len()
            && excluded.len() == self.excluded_topics.len()
            && interests.is_disjoint(&excluded)
            && self
                .depth_by_topic
                .keys()
                .all(|topic| interests.contains(topic))
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PreferenceSnapshot {
    pub preferences: PreferenceChoices,
    pub revision: i64,
    pub learned_reset_at: Option<String>,
    pub topics: Vec<TopicDefinition>,
}

pub fn preference_fixture() -> PreferenceSnapshot {
    PreferenceSnapshot {
        preferences: PreferenceChoices {
            interests: vec![Topic::CpuPerformance, Topic::Platform],
            depth_by_topic: BTreeMap::from([(Topic::CpuPerformance, TechnicalDepth::Advanced)]),
            excluded_topics: vec![Topic::Security],
        },
        revision: 1,
        learned_reset_at: None,
        topics: topic_catalog(),
    }
}
