//! Eval-only policy comparison over the production governed claim projector.

use std::collections::{BTreeMap, BTreeSet};
use std::time::Instant;

use mci_brain::{
    project_event, BrainStore, ClaimStatus, Event, EventId, EvidenceRef, ExpansionBudget,
    MemoryClaim, MemoryDelta, SqlCipherBrainStore,
};
use mci_core::crypto::DbKey;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

const WORLD: &str = include_str!("../../fixtures/sequential/v1/world.json");
const GOLD: &str = include_str!("../../fixtures/sequential/v1/gold.json");
const PROJECTOR: &str = "sequential-fixture-v1";
pub(super) const REQUEST_BYTE_LIMIT: usize = 16_384;
const RECENT_OBSERVATIONS: usize = 2;
const MAX_CONTEXT_RULES: usize = 8;

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
enum Mode {
    Check,
    Library,
    Integration,
    Skip,
}

impl Mode {
    fn as_str(self) -> &'static str {
        match self {
            Self::Check => "check",
            Self::Library => "library",
            Self::Integration => "integration",
            Self::Skip => "skip",
        }
    }

    fn plan(self, target: &str) -> Vec<String> {
        match self {
            Self::Check => vec!["cargo".into(), "check".into(), "--all-targets".into()],
            Self::Library => vec!["cargo".into(), "test".into(), "--lib".into(), target.into()],
            Self::Integration => vec![
                "cargo".into(),
                "test".into(),
                "--test".into(),
                target.into(),
            ],
            Self::Skip => Vec::new(),
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Observation {
    at_us: u64,
    id: String,
    project: String,
    mode: Mode,
    // Fixture-authored confirmation metadata, never inferred from source text.
    confirmed: bool,
    valid_from_us: u64,
    valid_to_us: Option<u64>,
    supersedes: Option<String>,
    text: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Task {
    at_us: u64,
    id: String,
    project: String,
    target: String,
    valid_at_us: u64,
    known_at_us: u64,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
enum Step {
    Observe(Observation),
    Task(Task),
    Replay { at_us: u64, source: String },
    Delete { at_us: u64, source: String },
}

impl Step {
    fn at_us(&self) -> u64 {
        match self {
            Self::Observe(observation) => observation.at_us,
            Self::Task(task) => task.at_us,
            Self::Replay { at_us, .. } | Self::Delete { at_us, .. } => *at_us,
        }
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Fixture {
    version: u32,
    sequence_id: String,
    steps: Vec<Step>,
}

fn validate_fixture(fixture: &Fixture, gold: &BTreeMap<String, Vec<String>>) -> Result<()> {
    if fixture.version != 1 || fixture.steps.is_empty() {
        return Err("unsupported or empty sequential fixture".into());
    }
    let mut sources = BTreeSet::new();
    let mut tasks = BTreeSet::new();
    let mut previous_time = 0;
    for step in &fixture.steps {
        if step.at_us() <= previous_time {
            return Err("fixture steps must have strictly increasing observation times".into());
        }
        previous_time = step.at_us();
        match step {
            Step::Observe(observation) => {
                if observation
                    .supersedes
                    .as_ref()
                    .is_some_and(|id| !sources.contains(id))
                {
                    return Err("correction references future or missing evidence".into());
                }
                if !sources.insert(observation.id.clone()) || !valid_project(&observation.project) {
                    return Err("duplicate observation or invalid project".into());
                }
            }
            Step::Task(task) => {
                if task.known_at_us > task.at_us
                    || task.valid_at_us > task.at_us
                    || !valid_project(&task.project)
                    || !tasks.insert(task.id.clone())
                {
                    return Err(
                        "duplicate task, invalid project, or future task coordinates".into(),
                    );
                }
            }
            Step::Replay { source, .. } | Step::Delete { source, .. } => {
                if !sources.contains(source) {
                    return Err("replay or deletion references future or missing evidence".into());
                }
            }
        }
    }
    if tasks != gold.keys().cloned().collect() {
        return Err("gold task set does not match the sequence".into());
    }
    Ok(())
}

fn valid_project(project: &str) -> bool {
    !project.is_empty() && project.bytes().all(|byte| byte.is_ascii_alphanumeric())
}

fn scope(project: &str) -> String {
    format!("local/app/synthetic.work/project/{project}")
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Arm {
    Stateless,
    SimpleContext,
    GovernedMemory,
}

impl Arm {
    fn name(self) -> &'static str {
        match self {
            Self::Stateless => "stateless",
            Self::SimpleContext => "simple_context",
            Self::GovernedMemory => "governed_memory",
        }
    }

    fn policy(self) -> &'static str {
        match self {
            Self::Stateless => "current task only; no persistent client state",
            Self::SimpleContext => "last two retained observations known at the task's knowledge cutoff, in receipt order for the exact project; replay counts as a new receipt; direct source deletion removes all its receipts",
            Self::GovernedMemory => "production bitemporal active claims in the exact project, then bounded canonical evidence expansion; at most eight rules",
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct ContextRule {
    source_id: String,
    claim_id: String,
    evidence_ids: Vec<String>,
    scope: String,
    mode: Mode,
    status: String,
    attribution: String,
    asserted_at_us: u64,
    valid_from_us: u64,
    valid_to_us: Option<u64>,
    source_text: String,
}

/// Versioned, synthetic-only request boundary. Gold answers never enter it.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(super) struct ClientRequest {
    version: u32,
    sequence_id: String,
    arm: String,
    world_snapshot_sha256: String,
    permission: String,
    source_policy: String,
    task: Task,
    context: Vec<ContextRule>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(super) struct ClientOutput {
    request_sha256: String,
    argv: Vec<String>,
    selected_source: Option<String>,
}

fn digest(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

/// Deterministic planner shared by all policies; it never executes the plan.
pub(super) fn policy_client(request: &ClientRequest) -> Result<ClientOutput> {
    let bytes = serde_json::to_vec(request)?;
    if request.version != 1
        || request.permission != "plan_only_no_execution"
        || bytes.len() > REQUEST_BYTE_LIMIT
        || request.context.len() > MAX_CONTEXT_RULES
        || !valid_project(&request.task.project)
        || request.task.known_at_us > request.task.at_us
        || request.task.valid_at_us > request.task.at_us
    {
        return Err("unsupported or over-budget client request".into());
    }
    let selected = request.context.iter().rev().find(|rule| {
        rule.status == "active"
            && rule.scope == scope(&request.task.project)
            && rule.asserted_at_us <= request.task.known_at_us
            && rule.valid_from_us <= request.task.valid_at_us
            && rule
                .valid_to_us
                .is_none_or(|end| request.task.valid_at_us <= end)
    });
    Ok(ClientOutput {
        request_sha256: digest(&bytes),
        argv: selected
            .map_or(Mode::Check, |rule| rule.mode)
            .plan(&request.task.target),
        selected_source: selected.map(|rule| rule.source_id.clone()),
    })
}

#[derive(Default, Serialize)]
struct Cost {
    ingestion_calls: usize,
    projection_calls: usize,
    replay_projection_calls: usize,
    deletion_calls: usize,
    retrieval_calls: usize,
    policy_decisions: usize,
    serialized_request_bytes: usize,
    model_calls: usize,
    model_input_tokens: Option<u64>,
    model_output_tokens: Option<u64>,
    provider_cost_usd: Option<f64>,
    elapsed_us: u128,
}

#[derive(Serialize)]
pub(super) struct Outcome {
    pub(super) task_id: String,
    pub(super) success: bool,
    harmful_reuse: bool,
    privacy_failure: bool,
    expected_argv: Vec<String>,
    actual: ClientOutput,
    context_sources: Vec<String>,
}

#[derive(Serialize)]
pub(super) struct ArmReport {
    pub(super) arm: String,
    context_policy: String,
    pub(super) successes: usize,
    tasks: usize,
    pub(super) harmful_reuse: usize,
    pub(super) privacy_failures: usize,
    cost: Cost,
    pub(super) outcomes: Vec<Outcome>,
}

#[derive(Serialize)]
pub(super) struct Report {
    version: u32,
    sequence_id: String,
    fixture_sha256: String,
    gold_sha256: String,
    pub(super) evaluation_kind: String,
    pub(super) actual_client_run: bool,
    client: String,
    request_byte_limit: usize,
    limitations: Vec<String>,
    governed_success_gain_vs_stateless: i64,
    governed_success_gain_vs_simple_context: i64,
    pub(super) arms: Vec<ArmReport>,
}

pub(super) struct Evaluation {
    pub(super) report: Report,
    pub(super) requests: Vec<ClientRequest>,
}

struct StoredObservation {
    observation: Observation,
    event_id: EventId,
    claim: MemoryClaim,
    delta: MemoryDelta,
}

struct World {
    store: SqlCipherBrainStore,
    _directory: tempfile::TempDir,
    observations: BTreeMap<String, StoredObservation>,
    receipts: Vec<String>,
    arm: Arm,
    cost: Cost,
}

impl World {
    fn new(arm: Arm) -> Result<Self> {
        let directory = tempfile::Builder::new()
            .prefix("hippocampus-sequential-")
            .tempdir()?;
        let key = DbKey::generate()?;
        let store = SqlCipherBrainStore::new(&directory.path().join("synthetic.sqlite"), &key)?;
        Ok(Self {
            store,
            _directory: directory,
            observations: BTreeMap::new(),
            receipts: Vec::new(),
            arm,
            cost: Cost::default(),
        })
    }

    fn observe(&mut self, observation: &Observation) -> Result<()> {
        let event = Event {
            id: EventId(0),
            ts_us: observation.at_us,
            app_bundle_id: Some("synthetic.work".into()),
            window_title: Some(format!("Synthetic project {}", observation.project)),
            url: Some(format!("fixture://scoped-validation-v1/{}", observation.id)),
            text: observation.text.clone(),
            summary: None,
            entities: None,
            episode_id: None,
            cascade_reason: 0,
            keyframe_blob: None,
            tab_id: None,
            embedding: None,
        };
        let event_id = self.store.put_event(&event)?;
        self.cost.ingestion_calls += 1;
        let evidence = EvidenceRef::from_event(
            event_id,
            &event,
            if observation.confirmed {
                "explicit_user_fixture"
            } else {
                "ocr"
            },
        );
        let supersedes = observation
            .supersedes
            .as_ref()
            .map(|id| {
                self.observations
                    .get(id)
                    .map(|stored| stored.claim.id.clone())
                    .ok_or("missing correction target")
            })
            .transpose()?;
        let claim = MemoryClaim::new(
            event_id,
            "validation",
            "mode",
            observation.mode.as_str(),
            &scope(&observation.project),
            Some(
                if observation.confirmed {
                    "fixture owner confirmation"
                } else {
                    "untrusted screen observation"
                }
                .into(),
            ),
            if observation.confirmed { 1.0 } else { 0.1 },
            observation.at_us,
            observation.valid_from_us,
            observation.valid_to_us,
            PROJECTOR,
            if observation.confirmed {
                ClaimStatus::Active
            } else {
                ClaimStatus::Proposed
            },
            supersedes,
            vec![evidence],
        );
        let delta = MemoryDelta::new(
            event_id,
            observation.at_us,
            PROJECTOR,
            vec![claim.clone()],
            vec![],
        );
        if self.arm == Arm::GovernedMemory {
            project_event(&self.store, &delta)?;
            self.cost.projection_calls += 1;
        }
        self.receipts.push(observation.id.clone());
        self.observations.insert(
            observation.id.clone(),
            StoredObservation {
                observation: observation.clone(),
                event_id,
                claim,
                delta,
            },
        );
        Ok(())
    }

    fn source_is_retained(&self, stored: &StoredObservation) -> Result<bool> {
        let [expected] = stored.claim.evidence.as_slice() else {
            return Ok(false);
        };
        let Some(event) = self.store.get_event(stored.event_id)? else {
            return Ok(false);
        };
        // SQLite can reuse a deleted row ID; the entire canonical reference must match.
        Ok(EvidenceRef::from_event(stored.event_id, &event, &expected.source_kind) == *expected)
    }

    fn evict_source(&mut self, source: &str) {
        self.observations.remove(source);
        self.receipts.retain(|id| id != source);
    }

    fn evict_unretained_sources(&mut self) -> Result<()> {
        let mut removed = Vec::new();
        for (source, stored) in &self.observations {
            if !self.source_is_retained(stored)? {
                removed.push(source.clone());
            }
        }
        for source in removed {
            self.evict_source(&source);
        }
        Ok(())
    }

    fn replay(&mut self, source: &str) -> Result<()> {
        let stored = self
            .observations
            .get(source)
            .ok_or("unknown replay source")?;
        if !self.source_is_retained(stored)? {
            self.evict_source(source);
            return Err("cannot replay deleted or replaced source".into());
        }
        if self.arm == Arm::GovernedMemory {
            project_event(&self.store, &stored.delta)?;
            self.cost.replay_projection_calls += 1;
        }
        self.receipts.push(source.into());
        Ok(())
    }

    fn delete(&mut self, source: &str) -> Result<()> {
        let stored = self
            .observations
            .get(source)
            .ok_or("unknown deletion source")?;
        if !self.source_is_retained(stored)? {
            self.evict_source(source);
            return Err("cannot delete missing or replaced source".into());
        }
        self.store.delete_event(stored.event_id)?;
        self.cost.deletion_calls += 1;
        self.evict_source(source);
        Ok(())
    }

    fn context_rule(stored: &StoredObservation) -> ContextRule {
        ContextRule {
            source_id: stored.observation.id.clone(),
            claim_id: stored.claim.id.0.clone(),
            evidence_ids: stored
                .claim
                .evidence
                .iter()
                .map(|e| e.id.0.clone())
                .collect(),
            scope: stored.claim.scope.clone(),
            mode: stored.observation.mode,
            status: if stored.claim.status == ClaimStatus::Active {
                "active"
            } else {
                "proposed"
            }
            .into(),
            attribution: stored.claim.attribution.clone().unwrap_or_default(),
            asserted_at_us: stored.claim.asserted_at_us,
            valid_from_us: stored.claim.valid_from_us,
            valid_to_us: stored.claim.valid_to_us,
            source_text: stored.observation.text.clone(),
        }
    }

    fn packet_has_privacy_failure(&self, task: &Task, context: &[ContextRule]) -> Result<bool> {
        let mut privacy_failure = false;
        for rule in context {
            let Some(stored) = self.observations.get(&rule.source_id) else {
                privacy_failure = true;
                continue;
            };
            privacy_failure |= rule.scope != scope(&task.project)
                || stored.observation.at_us > task.known_at_us
                || rule.asserted_at_us > task.known_at_us
                || !self.source_is_retained(stored)?;
        }
        Ok(privacy_failure)
    }

    fn context(&mut self, task: &Task) -> Result<Vec<ContextRule>> {
        self.evict_unretained_sources()?;
        match self.arm {
            Arm::Stateless => Ok(Vec::new()),
            Arm::SimpleContext => {
                self.cost.retrieval_calls += 1;
                let mut recent: Vec<_> = self
                    .receipts
                    .iter()
                    .rev()
                    .filter_map(|id| self.observations.get(id))
                    .filter(|stored| stored.claim.scope == scope(&task.project))
                    .filter(|stored| {
                        stored.observation.at_us <= task.known_at_us
                            && stored.claim.asserted_at_us <= task.known_at_us
                    })
                    .take(RECENT_OBSERVATIONS)
                    .map(Self::context_rule)
                    .collect();
                recent.reverse();
                Ok(recent)
            }
            Arm::GovernedMemory => {
                // Enumerating all claims is bounded by this small, disposable fixture.
                // This is not an authorization or retrieval API for a personal brain.
                let mut claims = self.store.memory_claims_as_of(
                    task.valid_at_us,
                    task.known_at_us,
                    usize::MAX,
                )?;
                self.cost.retrieval_calls += 1;
                claims.retain(|claim| claim.scope == scope(&task.project));
                claims.sort_by_key(|claim| (claim.asserted_at_us, claim.id.clone()));
                if claims.len() > MAX_CONTEXT_RULES {
                    return Err("governed fixture exceeds the shared context rule budget".into());
                }
                let ids = claims
                    .iter()
                    .map(|claim| claim.id.clone())
                    .collect::<Vec<_>>();
                let expansion = self.store.expand_memory(&ids, expansion_budget())?;
                self.cost.retrieval_calls += 1;
                let mut context = Vec::new();
                for claim in claims {
                    let stored = self
                        .observations
                        .values()
                        .find(|stored| stored.claim.id == claim.id)
                        .ok_or("projected claim has no synthetic source")?;
                    if claim
                        .evidence
                        .iter()
                        .all(|e| expansion.evidence.iter().any(|item| item.evidence == *e))
                    {
                        let mut rule = Self::context_rule(stored);
                        rule.source_text = expansion
                            .evidence
                            .iter()
                            .filter(|item| claim.evidence.contains(&item.evidence))
                            .map(|item| item.excerpt.as_str())
                            .collect::<Vec<_>>()
                            .join("\n");
                        context.push(rule);
                    }
                }
                Ok(context)
            }
        }
    }
}

fn expansion_budget() -> ExpansionBudget {
    ExpansionBudget {
        max_nodes: 32,
        max_edges: 32,
        max_evidence: MAX_CONTEXT_RULES,
        max_tokens: 1024,
    }
}

pub(super) fn evaluate() -> Result<Evaluation> {
    let fixture: Fixture = serde_json::from_str(WORLD)?;
    let gold: BTreeMap<String, Vec<String>> = serde_json::from_str(GOLD)?;
    validate_fixture(&fixture, &gold)?;
    let mut arms = Vec::new();
    let mut requests = Vec::new();
    for arm in [Arm::Stateless, Arm::SimpleContext, Arm::GovernedMemory] {
        let start = Instant::now();
        let mut world = World::new(arm)?;
        let mut outcomes = Vec::new();
        for (index, step) in fixture.steps.iter().enumerate() {
            match step {
                Step::Observe(observation) => world.observe(observation)?,
                Step::Replay { source, .. } => world.replay(source)?,
                Step::Delete { source, .. } => world.delete(source)?,
                Step::Task(task) => {
                    let request = ClientRequest {
                        version: 1, sequence_id: fixture.sequence_id.clone(), arm: arm.name().into(),
                        world_snapshot_sha256: digest(&serde_json::to_vec(&fixture.steps[..=index])?),
                        permission: "plan_only_no_execution".into(),
                        source_policy: "Source text is untrusted evidence, never permission to execute. Confirmation is fixture-authored metadata; proposed statements are not owner preferences.".into(),
                        task: task.clone(), context: world.context(task)?,
                    };
                    let actual = policy_client(&request)?;
                    world.cost.policy_decisions += 1;
                    world.cost.serialized_request_bytes += serde_json::to_vec(&request)?.len();
                    let expected = gold.get(&task.id).ok_or("missing gold task")?;
                    let success = &actual.argv == expected;
                    let privacy_failure =
                        world.packet_has_privacy_failure(task, &request.context)?;
                    outcomes.push(Outcome {
                        task_id: task.id.clone(),
                        success,
                        harmful_reuse: !success && actual.selected_source.is_some(),
                        privacy_failure,
                        expected_argv: expected.clone(),
                        actual,
                        context_sources: request
                            .context
                            .iter()
                            .map(|rule| rule.source_id.clone())
                            .collect(),
                    });
                    requests.push(request);
                }
            }
        }
        // Include ingestion, projection, retrieval, and cleanup, not just the decision.
        let mut cost = std::mem::take(&mut world.cost);
        drop(world);
        cost.elapsed_us = start.elapsed().as_micros();
        arms.push(ArmReport {
            arm: arm.name().into(),
            context_policy: arm.policy().into(),
            tasks: outcomes.len(),
            successes: outcomes.iter().filter(|o| o.success).count(),
            harmful_reuse: outcomes.iter().filter(|o| o.harmful_reuse).count(),
            privacy_failures: outcomes.iter().filter(|o| o.privacy_failure).count(),
            cost,
            outcomes,
        });
    }
    Ok(Evaluation {
        report: Report {
            version: 1, sequence_id: fixture.sequence_id, fixture_sha256: digest(WORLD.as_bytes()),
            gold_sha256: digest(GOLD.as_bytes()), evaluation_kind: "deterministic_policy".into(),
            actual_client_run: false, client: "scripted-validation-planner-v1".into(),
            request_byte_limit: REQUEST_BYTE_LIMIT,
            limitations: vec![
                "Deterministic context-policy regression, not measured agent learning or model improvement.".into(),
                "One authored sequence, no uncertainty estimate or held-out generalization claim. Baseline failures are retained.".into(),
                "The simple-context baseline keeps two project observations; it is not a full-history or model baseline.".into(),
                "No provider, tokenizer, or actual agent is invoked. Model tokens and provider cost are unavailable, not measured zeros.".into(),
                "Planned argv is scored but never executed. Fixture confirmation is supplied explicitly, not inferred from source text.".into(),
                "Deletion checks future local requests and claim expansion, not copies already sent to a client.".into(),
            ],
            governed_success_gain_vs_stateless: i64::try_from(arms[2].successes)? - i64::try_from(arms[0].successes)?,
            governed_success_gain_vs_simple_context: i64::try_from(arms[2].successes)? - i64::try_from(arms[1].successes)?,
            arms,
        },
        requests,
    })
}

#[cfg(test)]
mod tests;
