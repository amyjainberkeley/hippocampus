# Hippocampus Product Direction

## Recommendation

Hippocampus should be a personal work-memory product: it preserves permitted evidence of work, helps someone recover their train of thought, explains their day, and supplies relevant context to the agents they choose. Its primary promise is continuity, not recording volume, a productivity score, or a new chat destination.

The product should feel unexpectedly useful in ordinary moments. Someone returns to a project and finds the last decision, the unresolved question, and the exact source already together. Someone remembers a diagram but not its filename and can recover it visually. Someone starts a new agent session without reconstructing yesterday's context. These are proposed experiences, not claims about the current build.

The design standard is relentlessly impressive work: accurate evidence, fast responses, restrained presentation, graceful recovery, and considerate defaults. Delight should result from a burden disappearing. It should never depend on fabricated knowledge, constant interruption, or overstating what the computer observed.

This is a research and discussion proposal. It does not authorize a new implementation, establish release readiness, or supersede [the product status ledger](../STATUS.md). Public-source observations are current to September 8, 2026 unless dated otherwise. Competitor capabilities below are documented vendor claims, not results from installing and testing their products.

## The Actual Opportunity

Local memory is not empty territory. Screenpipe already describes computer-history capture for agents. Dayflow presents an automatic work journal with summaries. Minimi offers personal context and open-loop assistance. Turnstone positions a local shared brain across sources and agents. A screenshot recorder with search, summaries, and MCP therefore cannot reasonably be described as a unique category invention.[^1][^2][^3][^4]

Nor is there enough comparable public evidence to say nobody has won. Installations, launch votes, funding, social views, GitHub stars, and retained paying users measure different things. The available evidence supports a fragmented set of products and jobs, not a defensible ranking by daily use or customer love.

The opportunity worth testing is narrower and more demanding: dependable work continuity across applications and agents, grounded in inspectable evidence. The important questions are not merely whether information was saved, but which project it belongs to, what changed, whether an earlier decision still applies, and whether sharing it would help this particular task.

This also changes the competitive thesis. Model companies and operating-system vendors can build memory; Microsoft already offers Recall. Meta describes personal superintelligence and acquired Limitless. A sustainable strategy cannot assume that these companies cannot afford to compete. Cross-tool independence, user ownership, reliable capture, and earned trust are potential advantages that must be demonstrated, not an established moat.[^5][^6][^7]

The exact public program name "Meta Model Context Initiative" has not been verified. The useful interpretation here is the broader aspiration toward personal context that assists its owner. It should not be presented as an established Meta specification, or as evidence of why a particular Meta initiative succeeded or failed.

## Demand And Everyday Use

The strongest demand hypothesis is less reconstruction: finding something again, resuming an interrupted task, and explaining less to AI. The 2025 Stack Overflow survey found that 66% of respondents to its frustration question encountered nearly correct AI answers, and 45% cited time-consuming debugging. That supports a need for dependable assistance, but does not establish that missing memory caused those errors. It is a self-selected developer survey, not a 2026 consumer market estimate.[^8]

Older human-computer interaction research provides a useful behavioral foundation. A 2004 study found that people often recovered information through contextual steps rather than a fully specified keyword query. A 2007 field study examined suspended work and the difficulty of reconstructing its context. These studies support designing for recognition and resumption; their age and populations make them unsuitable for estimating current demand or minutes saved.[^9][^10]

| Job someone needs done | Concrete benefit | What must be learned from users |
| --- | --- | --- |
| Find something seen earlier | Recover the exact passage, image, or source without knowing its title | How often this happens and whether existing search already solves it |
| Resume meaningful work | Restore the last decision, open question, and relevant materials | Whether the reconstruction is correct and actually faster |
| Give an agent context | Avoid repeating background and obsolete instructions | Whether task outcomes improve, not just prompt length |
| Understand the day | See actual work distribution, changes, and unresolved intentions | Whether the insight changes a useful decision |
| Prevent repeated work | Surface an earlier answer, rejected approach, or superseded decision | Whether false matches create more work than they save |

The initial audience should be individuals who work across several applications and use AI frequently: founders, product managers, designers, researchers, consultants, and developers. Developers are valuable early testers, but not the only plausible buyers. Someone who can assemble a notes vault still may value reliable capture, maintenance-free retrieval, and trustworthy delivery. Someone who cannot configure MCP should still receive a complete product.

Accountability is a secondary benefit. Leading with monitoring or distraction detection risks making an assistant feel like a supervisor. The stronger initial promise is support: understand what happened, recover what matters, and continue with less effort. Voluntary coaching can become a distinct preference once measurement and interpretation deserve trust.

## Competitive Landscape

| Product | Documented focus | Implication for Hippocampus |
| --- | --- | --- |
| Minimi / Shram | Personal context through Cotton and commitments through Melody; its memory page says it uses Accessibility rather than screenshots | Visual evidence can distinguish the implementation, but remembering context and open loops already overlap directly.[^3] |
| Turnstone | Local knowledge across connected sources and agents, with a workspace built around that knowledge | Avoid competing only on a shared-brain slogan. Prove continuity inside tools people already use.[^4] |
| Screenpipe | Screen and application context, local history, agent access, and automation; its current site describes it as source-available | Capture plus MCP is already a direct competitive proposition. Product reliability and usefulness need comparison, not assumption.[^1] |
| Dayflow | Automatic work journal, time-oriented views, daily and weekly outputs, with local or cloud model choices | A daily timeline is not enough differentiation. A review must explain meaningful work and support the next action.[^2] |
| HeyClicky | Invoked screen-aware assistance; its trust page says capture happens on hotkey, processing is cloud-based, and raw screenshots are not retained | Learn low-friction interaction, not continuous-memory architecture. These are different products.[^11] |
| Microsoft Recall | Opt-in encrypted local snapshots, search, timeline, filtering, and storage controls on supported Windows hardware | Operating-system distribution is a real threat. A Mac product needs value beyond a searchable screenshot archive.[^5] |
| Mem0 / OpenMemory | Memory infrastructure and cross-client access; local OpenMemory and hosted Mem0 MCP are separate offerings | Infrastructure does not replace desktop capture and consumer onboarding, but reusable memory alone is not differentiated.[^12][^13] |
| Obsidian | User-owned files, local knowledge, and extensibility | It is not a failed Hippocampus. It serves intentional knowledge work and is a useful export destination.[^14] |
| Granola | Meeting-derived notes expanding into shared context and integrations | A specific useful artifact can be a stronger entry point than a broad promise to remember everything.[^15] |
| Raycast | A recurring command interface with extensible desktop capabilities | Study an interaction that fits work already happening; do not require people to visit a dashboard repeatedly.[^16] |
| Timing / ActivityWatch | Activity measurement and tracking with explicit treatment of idle state | Learn measurement discipline before offering hours, percentages, or productivity judgments.[^17][^18] |
| Limitless / Rewind | Limitless announced its Meta acquisition and the end of Rewind capture in December 2025 | Durability and an exit path matter. A product transition is not proof of business failure, but it exposes continuity risk for users.[^6] |

There are important privacy distinctions behind similar language. Minimi describes local embedding storage while also disclosing Gemini processing and backend relays to Gemini and Deepgram. "Stored locally" should not be interpreted as "never transmitted." Its benchmark claim is vendor-reported and not a measurement of desktop capture completeness.[^3]

HeyClicky's changelog also offers a useful product lesson: it describes adding hands-on onboarding after people missed features, reducing UI noise, and fixing responsiveness problems involving Accessibility queries. These are specific engineering and interaction decisions worth studying, not proof that Hippocampus should copy its identity.[^19]

The five adaptations worth exploring are a short live onboarding exercise, one lightweight entry point available from other apps, no blocking background work on the UI thread, contextual actions close to the evidence, and progressive disclosure. Each must be implemented in Hippocampus's native language and verified locally, not reproduced as visual imitation.

## Why The Category Remains Fragmented

The following are analytical explanations, not established causes of any named company's performance.

**Value arrives after trust is requested.** A recorder asks for unusually broad permissions before it has accumulated anything useful. A convincing first-use proof must shorten that gap without secretly importing unrelated personal history.

**More capture can make the product worse.** Repeated UI chrome, duplicated text, stale versions, private conversations, and images without readable text can overwhelm retrieval. The winner needs selection and chronology, not just a growing database.

**Retrieval and understanding are different products.** Finding a screenshot is easier to verify than claiming that someone finished a task or changed their mind. Mixing those truth levels produces a system that appears fluent but becomes hard to trust.

**A passive archive has an uncertain habit.** Recall is valuable when something is lost, but that moment may not occur every day. Daily reviews and agent delivery can create recurring value, provided they do not become repetitive summaries or noisy notifications.

**Resource use and failure are visible.** A local recorder shares the user's battery, CPU, disk, and working environment. Historical Screenpipe reports include high resource use alongside reassuring health UI. That closed 2024 issue illustrates a failure mode, not a claim about the current release.[^20]

**Platform and business boundaries are unsettled.** Local-first storage, optional cloud inference, subscription access, device management, and team sharing are different promises. Combining them casually can create confusing privacy claims, unpredictable costs, and unsupported integrations.

These tensions explain why a credible product needs a complete interaction loop. They do not establish that the market is impossible or that a particular startup will break out.

## Product Structure

Three approaches are plausible. An archive-first product is easy to understand and verify but may be used only when something is missing. An agent-first utility fits existing AI workflows but risks becoming invisible infrastructure. A coach-first companion offers a daily habit but depends on the most difficult inference and the most sensitive judgments.

The recommendation combines their strongest parts under work continuity: Today supplies a useful interpretation, Search recovers evidence, and History makes the record inspectable. Agent handoff is an action available throughout, not another copy of the same feed. Coaching remains optional.

### Sidebar

| Destination | The question it answers | Distinct main content |
| --- | --- | --- |
| Today | What moved forward, what needs attention, and where should I resume? | Short synthesis, measured work distribution, confirmed intentions, and a small number of relevant next steps |
| Search | Where is the thing I remember? | Prominent search field, match-centered results, source images, and optional grounded answers |
| History | What did the computer actually observe? | Chronological sessions, captures, changes, and explicit gaps with evidence inspection |
| Pinned projects, later | What is the current state of this ongoing body of work? | A scoped decision and evidence history, only after project attribution works |
| Connections, Privacy, Settings | What is connected, recorded, shared, and retained? | Quiet lower-sidebar configuration and inspectable status |

Brief is an output of Today, not a destination. Sessions are a grouping inside History. Sources belong in Connections and result provenance unless there is a distinct source-management job. A separate Insights tab should be added only if users actually need longitudinal analysis beyond Today and project views.

Search should start with an inviting, immediately focused search field, not a wall of yesterday's captures. Results need the matching passage rather than the start of an OCR transcript, the relevant image region, readable provenance, and one route to the surrounding history. Empty and no-match states must distinguish no captures, active filters, unreadable text, and no relevant result when the system can establish the distinction.

Today should contain a concise interpretation, not expose database structure. A chart can explain distribution, but the useful content is what changed, which planned outcomes remain unresolved, and what would help someone resume. Clicking a claim should open the evidence; clicking a chart segment should reveal the intervals behind it.

Native materials, compact spacing, legible text, keyboard navigation, and responsive controls matter more than decoration. A simple recognizable icon needs to work at Dock, menu-bar, and small sidebar sizes; an ornate anatomical illustration is not required. Branding should follow the product shape, not consume the reliability budget.

## Aha Moments

The examples in this section are synthetic experience concepts. They are not observations of anyone's work and are not current capabilities.

| Moment | Experience | Evidence required before showing it |
| --- | --- | --- |
| "I found it without knowing its name" | A query about the blue architecture diagram from last week opens the correct image and its surrounding discussion | Visual match, date/source identity, and recoverable evidence; text-only retrieval must not pretend it inspected the diagram |
| "It remembered where I stopped" | Returning to a project reveals the last open question and the material already considered | Reliable project scope, ordering, and a distinction between a recorded question and inferred intent |
| "My agent didn't make me repeat myself" | An approved new session receives current decisions and constraints, with sources available on demand | Actual client delivery, freshness, bounded scope, and resolvable citations |
| "That explains why the day felt fragmented" | A review separates project work, communication, and unobserved time, and shows repeated transitions when measured | A real interval ledger and clear classification, not screenshot counts or a guess about attention |
| "I had already solved this" | Relevant earlier work appears when a current question closely matches it | A sufficiently specific match, evidence that the prior answer is still applicable, and easy dismissal |
| "It caught something before it slipped" | A confirmed commitment is linked to a later changed deadline or missing confirmation | Correct speaker, commitment confirmation, temporal updates, and no assumption that absence of a capture proves noncompletion |

Surprises should normally appear when the user opens Today, searches, resumes a project, or asks an agent. Outside-app nudges need a separate opt-in, a meaningful reason, a rate limit, and a simple way to correct or silence them. A memory product should not create more context switches than it saves.

Prioritize the first three experiences. They create value before the system is trusted to interpret productivity or act autonomously. Daily understanding should be developed alongside the measurement foundation, not substituted with generic encouragement while that foundation is missing.

## An Honest Daily Review

A synthetic five-hour review could show 2 hours 10 minutes of classified project work, 50 minutes of communication, 40 minutes of research, 20 minutes unclassified, and 1 hour unobserved. The categories total five hours; the unknown hour remains visible. Percentages are 43.3%, 16.7%, 13.3%, 6.7%, and 20.0% of that stated window, respectively. These are illustrative values, not measurements.

The distinction matters. Input activity, a foreground window, reading, thinking, and work completed are not interchangeable. WhatsApp can be necessary work. A quiet keyboard can mean careful reading. Idle detection alone should not label that period either wasted or productive.

A useful review should separately answer four questions: what was observed, which project or activity it likely concerned, what changed in the work, and how that relates to intentions the person actually confirmed. Classification can be corrected. Confirmed completions must remain distinct from suggested completions and unknown outcomes.

For example, "Two of three confirmed intentions are marked complete; the third has no confirmed outcome" is defensible when backed by those records. "You failed to finish the third" is not. A comparison against yesterday also requires comparable coverage; an apparent drop during a capture outage should not become a behavioral insight.

Begin with deterministic interval accounting and evidence-linked changes. Add local synthesis only when it makes those records more understandable without inventing them. The product can be candid and encouraging without diagnosing motivation or assigning a moral value to screen time.

## Memory Architecture

The following is a proposed architecture, not a claim that every layer exists today.

| Layer | Responsibility | Invariant |
| --- | --- | --- |
| Evidence | Permitted image, visible text, source, timestamps, and acquisition status | Derived understanding can always identify its source while that source is retained |
| Activity intervals | Foreground changes, input-idle observations, lock, sleep, pause, and unavailable periods | Time accounting never silently fills an unobserved interval |
| Sessions and projects | Group related work and preserve meaningful transitions | Group membership is revisable and cannot grant broader agent access |
| Claims and intentions | Decisions, possible commitments, confirmed outcomes, and superseding observations | Speaker, time, confidence, and confirmation state remain explicit |
| Retrieval and context | Select evidence for this question or client task | Small relevant packets with citations; no unrestricted personal-history dump |

Capture should combine permitted Accessibility text with OCR and selected visual evidence. Accessibility can recover exact text that OCR misses; OCR and images can preserve information unavailable through Accessibility. Disagreement should be retained as a quality signal rather than silently manufacturing a single certain transcript.

The screen is a broad observation surface, not the full truth of the computer. Hidden tabs, server-side changes, unsaved intent, and whether an operation really succeeded may remain unknown. Focused-window capture is a reasonable safer default; fuller visible-display capture should be an explicit mode only when exclusions and region handling are qualified. More pixels are not automatically more useful context.

Do not add raw keylogging or clipboard collection merely to claim completeness. Structured file or application integrations can improve selected tasks later, with their own consent and source labels. Recording permission is not permission to send information to a model, and neither implies permission to take action.

Evidence and derived records need a clear relationship. Preserve source identifiers and versions, make summaries rebuildable, and record corrections as changes rather than overwriting history invisibly. Deleting evidence must invalidate or remove dependent excerpts, embeddings, summaries, and queued handoffs. Already transmitted copies cannot honestly be promised to disappear from another provider or an agent's conversation.

### Retrieval Without An Indiscriminate RAG Dump

Start with interpretable text search, time and application filters, query-centered excerpts, deduplication, and expansion to adjacent evidence. Add semantic retrieval or reranking only when a held-out test shows an improvement on real question types. A vector database is neither a product strategy nor inherently a mistake.

The useful idea in an event-log design is preserved chronology, provenance, replayable derived views, and explicit state changes. "No vector database" alone is not evidence of exceptional engineering. Nothing in this research establishes that Runlog should replace Hippocampus's store; reuse should follow an independent code, license, integrity, and benchmark evaluation rather than a wholesale merge based on that claim.

Answer generation should happen after evidence collection. Some queries need exact text; others need the image; others require following a decision across several days. Summarizing everything in advance risks throwing away the detail that a future question needs. Keeping everything forever, conversely, creates cost and privacy problems. The system needs explicit retention and accountable compression, not a magical lossless-memory claim.

### Research Implications

| Research | Relevant result or design | Proposed use and limitation |
| --- | --- | --- |
| ReFind, August 2026 | Agent-controlled lexical search over raw chat histories uses session, time, neighboring context, and redundancy controls | Establish a strong simple baseline before elaborate memory structures. Its text-chat results do not demonstrate desktop OCR quality.[^21] |
| M3Exam / M3Proctor, June 2026 | Examines multimodal memory and explores accessing raw visuals when needed | Retain a route back to images instead of treating OCR as complete evidence. Reported benchmark savings are not Hippocampus forecasts.[^22] |
| MemoryOS, May 2025 | Separates storage, updating, retrieval, and generation across memory levels | Separate recent context from durable personal facts and update them deliberately; adopting the entire framework is not required.[^23] |
| LifeBench, March 2026 | Tests long-horizon, multi-source memory including inferred behavioral structure | Test months of changes, contradictions, and unknowns. Its reported 55.2% top result is specific to that benchmark, not a universal accuracy ceiling.[^24] |
| BEAM / LIGHT, revised February 2026 | Long conversations stress memory beyond simple recall; working, episodic, and scratchpad components are evaluated | Include changing facts and sustained context in evaluation. A vendor's score is not comparable without its model, setup, and evaluation details.[^25] |
| Anthropic context engineering, September 2025 | Emphasizes selecting useful context and retrieving it at the right time | Bound agent packets and let the agent inspect further evidence; avoid constantly appending a person's whole day.[^26] |

These works support experiments, not an announcement that memory is solved. Conversational benchmarks omit many of the hard desktop problems: permission loss, small fonts, duplicate windows, screen-only private content, partial observation, and unavailable evidence.

### Learning From Experience

Continual Learning Bench adds a relevant evaluation lens. Its May 4, 2026 release evaluates related task sequences rather than isolated questions.[^37] The June paper compares systems with their own stateless versions, reporting reward, learning gain, and cost. Preserving context was a strong baseline against more elaborate memory systems in its experiments. Its six domains and relatively short sequences do not qualify desktop capture, months of personal use, or local-model performance; the initial study does not evaluate weight-training approaches.[^38]

The proposed product test is therefore not only "can it find an old fact?" but "does the next piece of work improve because earlier experience is available?" That is an additional usefulness test, not a replacement for capture and privacy qualification. No continual-learning benchmark has been run on Hippocampus at this checkpoint.

Four forms of memory should have different update rules:

| Memory | Example, synthetic | Rule |
| --- | --- | --- |
| An observed episode | A design was reviewed and a concern appeared in the discussion | Preserve its source and time; do not turn every sentence into a standing instruction |
| Current project state | A deadline was explicitly revised | Retain the earlier record but mark which state supersedes it and why |
| A confirmed preference | For this project's updates, lead with decisions and omit background already known to the recipient | Store the scope, confirmation, and a way to change or remove it |
| A useful procedure | A particular validation sequence worked for this repository and version | Keep the prerequisites and outcome evidence; treat reuse as a proposal, never as permission to execute |

These can be explicit local records supplied to an agent; the first implementation does not need to retrain Claude or Codex. The point is observable adaptation of the combined system, not a claim that a provider model's weights changed. More aggressive learned representations can remain experiments until their benefits, deletion behavior, and resource costs are demonstrated.

A correction should become a durable, inspectable change, not merely another sentence buried in history. Record what changed, the affected scope, whether it came from an explicit user correction or an inference, and which older interpretation it replaces. Recheck dependent summaries and future context packets. An inferred pattern should remain tentative until supported or confirmed; a webpage, quoted instruction, or an agent's self-congratulation cannot establish the owner's preference or a successful outcome.

For example, a person corrects the classification of a work conversation once. Later relevant reviews should apply that scoped correction, but it should not label all communication as work. A project changes its deployment process; future handoffs should use the new process while retaining the historical reason for the change. These are testable proposed improvements, not automatic consequences of saving more screenshots.

### Experience-Gain Evaluation

Add an isolated test harness for the following proposed comparison. These are Hippocampus-specific evaluation arms, not claimed CL-Bench results or an unmodified reproduction of its protocol.

| Arm | Available history | Question it answers |
| --- | --- | --- |
| Stateless | Current task only, with all persistent agent state reset | How much can the base system already do? |
| Simple context | An explicitly specified recent-history policy; also full history where it fits | Does a straightforward context baseline suffice? |
| Hippocampus | The proposed scoped evidence, corrections, and retrieval path | Does the extra memory machinery improve outcomes enough to justify its cost? |

Borrow the basic gain comparison: task reward with state minus task reward without it.[^38] Also compare Hippocampus directly with the simple-context arm. Report absolute task success, repeated mistakes, unnecessary questions, time, total tokens, and privacy failures separately. Include ingestion, summarization, retrieval, and retries in the cost rather than counting only the final answer.

Use the same declared model version, tool permissions, generation settings, and resource ceilings, with a documented context-selection policy per arm. Reset writable files, client memory, caches that contain task knowledge, and conversations between independent runs so a supposedly stateless agent cannot recover an earlier answer indirectly. Reveal only evidence available before each task, never future events or hidden answer keys. Repeat sequences and report uncertainty, including negative gain.

Use disposable fixtures, never the person's actual working directory. Each arm must receive an equivalent task-world snapshot at each comparison point; removing agent knowledge must not also remove required task inputs or make one arm's environment easier.

The fixture should include both positive transfer and traps: a correction that should generalize within one project, an unrelated project where it must not apply, a process that changes, a formerly useful rule that expires, a deleted source, and a malicious screen instruction. Later tasks should require applying the lesson in a new situation, not merely reciting the earlier correction. Use objective task checks where possible and blinded human review for judgment-heavy outcomes.

Prefer explicit, editable memory until this comparison shows a reason to add complexity. Trial new ranking or consolidation policies on synthetic fixtures or in a separately consented shadow evaluation, with versioned outputs and rollback. Do not let a self-improvement loop rewrite capture exclusions, expand agent permissions, or delete evidence in pursuit of a better score.

### Later Companion Interface

A small optional companion in the app's lower-right corner is a later presentation idea, not an immediate build item. It should expose the same qualified memory and actions already available through Today, Search, and History, not introduce a separate untraceable memory store or become necessary for using the app.

Its useful interactions could be "where did I stop?", "what changed?", "why do you think that?", and "give this context to my agent." A response should lead to the relevant evidence, accept a correction, and explain external sharing when applicable. Begin with invocation by the user; unsolicited nudges require a separate preference. Avoid idle animation, sound, content-obscuring placement, or pretending to know the user's attention or mood.

Hiding the companion must not be confused with pausing capture, and neither should silently alter sharing permissions. Provide distinct, accessible controls. Its release condition is that an existing useful task becomes quicker or clearer through this interface, not merely that an appealing character can be rendered.

## Agent Delivery And Compute

The default local path should perform capture, text indexing, search, retention, and time accounting without a cloud model. Optional local synthesis should be qualified on named hardware. More capable external reasoning can operate in a chosen agent or through an explicitly configured API, with a preview of what leaves the Mac and a spending limit.

A supported client connection should include discovery, consent, installation, a test request, and an observable delivery result. A configured MCP server is not proof that a client read it. A hook firing is not proof the answer used its contents. Claude's documented SessionStart hook provides a real integration point, but client lifecycle behavior still requires testing.[^27]

Each packet should identify its project, time range, freshness, source citations, and unavailable or withheld context. Long-running sessions need task-driven refresh, not merely a packet at startup. Background retrieval should be bounded and fail without delaying the user's agent indefinitely. Project aliases and inferred grouping must never broaden a client's authorization.

There is an important business constraint around subscription use. Anthropic currently distinguishes an end user signing into the unmodified Claude Code client from a third-party application collecting credentials or routing its own requests through consumer-plan credentials. The latter is not an acceptable default product dependency. Use supported client integrations or authorized API paths; confirm applicable terms before promising subscription-powered background inference.[^28]

For local-only operation, adding users does not create a central per-screenshot inference bill, but it still creates distribution, support, security, and maintenance costs. Cloud features scale with calls, tokens, images, retention, and model choice. No credible current dollar estimate follows from user count alone.

A cost experiment should replay the same consented or synthetic day through each proposed configuration and record calls, tokens, elapsed time, hardware load, and actual provider rates. A capped per-user budget with queued batch work and graceful fallback is safer than an unlimited promise. Doubling the number of agents should not cause every agent to repeat the same summary job.

### Storage Budget

Disk storage and runtime memory are different constraints. As an illustrative calculation, eight hours per day for sixty days at one 200 KB screenshot every thirty seconds produces 57,600 images, or 11.52 GB before metadata, indexes, encryption overhead, and backups. At five-second intervals the same assumptions produce 69.12 GB. Actual sizes must be measured.

The recommended design uses content-change detection, duplicate suppression, adaptive keyframes, a bounded image budget, and separate retention controls for text and images. Preserve user-pinned evidence. Show the measured daily growth and estimated remaining capacity. Do not silently delete images while implying that every old claim still has visual proof.

Compression is a tradeoff: discarding a frame can lose text or a visual detail that later matters. Test retention policies against refinding questions before adopting them. A small current database is not a forecast of sixty days of screenshot memory, and a compact summary is not a substitute for every original source.

## Onboarding And Trust

The first-use sequence should prove a small real outcome. Explain the local capture boundary, ask for the minimum permissions, show what is currently being captured, and let the person use a harmless visible page. Then retrieve that newly captured page, reopen its image, and optionally deliver its context to one selected agent.

The experience should require no pasted configuration file. But simplifying setup must not hide consent: show which client is being connected and which scope it receives. If an integration cannot be completed automatically, present the actual remaining step rather than marking it connected. Model download, storage, and any cloud processing must be explicit.

Three trust controls should always be easy to reach: pause, exclude this source, and delete recent memory. Health must distinguish permission granted, stream running, last saved evidence, index freshness, and agent delivery. A green process indicator is not proof that new memories are being stored.

Treat captured text as untrusted content, including visible instructions aimed at an agent. Retrieval cannot authorize shell execution or broaden sharing. Future actions such as sending messages or editing files need explicit authorization, a preview or bounded policy, and recovery where feasible. Private exclusions must apply to screenshots, OCR, indexes, derived insights, exports, and diagnostics, not just the main database.

## Current Code And Proposed Build Order

At source baseline `5bcb382afe7518962b9a4174c3a55dc3c0c6e433`, the record supports an existing native app and substantial components, but not the complete product described here. The status ledger records installed product baseline `fe90a3d` and open live qualification gates. This research does not rerun or advance those gates.[^29]

| Area | Source-backed state | Required next behavior |
| --- | --- | --- |
| Daily Review | Deterministic last-context, returned-app, and capture-gap observations | Actual work synthesis and interval-backed accounting, not more sample headings.[^30] |
| Brief | A keyword-oriented extractive author exists | Evidence-based changes, decisions, and uncertainties rather than generic bullets.[^31] |
| Search | Shared result formatting uses a prefix of event text; lexical search itself is not limited to that prefix | Match-centered excerpts and visual grounding, alongside capture and OCR completeness qualification.[^32] |
| Activity | An input-idle reader and adaptive capture schedule exist | A durable interval ledger; sampling cadence is not measured work time.[^33] |
| Agent handoff | A bounded Claude SessionStart context hook exists | Verified lifecycle delivery and correct task scope, plus separate qualification for every other claimed client.[^34] |
| Release | Signed installation is recorded; important end-to-end evidence remains open | Same-build capture, privacy, recovery, and distribution qualification before a public readiness claim.[^29] |

The build order is governed by observable outcomes, not elapsed hours or commit counts. UI sketches and user interviews can happen in parallel; intelligence claims cannot bypass the evidence foundation.

| Gate | Required observable result | What does not count |
| --- | --- | --- |
| 0. Identity | Installed app, helper, effective policy, store, and source baseline are matched | A passing build in another worktree |
| 1. Capture and recall | A fresh phrase generated only in a real window becomes a screen-origin record; the matching authenticated image reopens after restart; recall finds it | Imported text, rising event counts, or unrelated blob files |
| 2. Privacy and recovery | Exclusion, pause, lock, revocation, crash, disk failure, deletion, and resume behave correctly and visibly | A surviving process or a green status indicator |
| 3. Agent continuity | An actual supported client receives fresh scoped evidence, resolves citations, and avoids unrelated or excluded material | A config entry, mocked hook, or manually pasted context |
| 4. Daily understanding | Intervals reconcile; unknown time stays unknown; useful summaries and images trace to evidence | A donut chart computed from screenshot counts |
| 5. Commitments and distribution | Attributed intentions can be confirmed and updated; the final signed build passes supported-machine install and update checks | Treating a quoted promise as the owner's commitment or signing an unqualified build |

Each gate needs an implementation change where necessary, regression tests, a live proof, and a concise receipt of what passed and what did not. Resume testing must check stored evidence, not only stream callbacks. No overnight-reliability claim should be made from a few successful minutes.

### Quality Evaluation

Build a versioned synthetic work history with separate ground truth and a held-out question set. Include small text, diagrams, duplicate frames, same-named projects, revised deadlines, quoted commitments, another person's task list, multiple displays, lock gaps, excluded windows, and a source deleted after summarization. Separate injected-dataset retrieval tests from actual screen-capture tests.

Report capture completeness, OCR word and character error, answerability, retrieval recall at a stated rank, citation validity, false claims, cross-project leakage, latency, and resource consumption. Do not collapse them into one flattering score. A model-generated judge should not be the only evaluator, particularly for attribution and privacy.

Proposed initial targets are zero observed excluded-content leaks in the test suite, every displayed factual claim linked to retained evidence or a clearly labeled user confirmation, and at least 95% recall within the first five results for held-out known-item text questions on the declared fixture. These are targets, not achieved results or statistical guarantees. Visual and semantic queries need separate scores. Any privacy breach blocks release even when average retrieval is excellent.

For usability, measure time to first recovered source, success reconnecting after a restart, and whether a fresh agent session completes a real task with less explanation. Compare against the person's existing workflow, not against no tools. A small longitudinal pilot should record which useful moments recur, which suggestions are wrong, and whether people voluntarily keep capture enabled after the novelty passes.

## Commercial And Open-Source Direction

Begin with a personal product, not an employer dashboard. The early commercial hypothesis is that frequent cross-application workers will pay for reliable continuity and low maintenance. Test that hypothesis with an actual price and a working experience; enthusiasm for a demo is not willingness to pay.

Team features should first share selected outputs: an approved project brief, decision history, or handoff. Do not make private screen history visible to managers by default. Enterprise distribution, access controls, procurement, and security assurance form another product commitment and should be priced and staffed accordingly.

Local-first principles emphasize ownership, offline usefulness, and durable access. Those principles fit a memory product whose usefulness grows over time. The ability to read and export existing memory should not disappear because a subscription ends or a company changes direction.[^35]

The repository has an Apache-2.0 root license. That does not replace a review of dependency licenses, model redistribution, inconsistent file headers, branding rights, or security before an open-source launch.[^36] The public engineering story should show clear architecture, reproducible synthetic tests, known limitations, migrations, meaningful release notes, and a vulnerability-reporting process. Raw private capture data never belongs in that story.

The immediate commercial differentiator should not be "more sophisticated than Obsidian" or "no vectors." It should be demonstrable: the right evidence reappears when needed, a fresh agent continues correctly, and the user can understand and control why.

## Decisions For Collaborative Design

The recommended starting decisions are three primary destinations, work continuity as the core job, visible source evidence, local core processing, opt-in external delivery, and quiet contextual assistance. The major remaining choice is how proactive the product should feel outside its own window.

The continual-learning extension adds a further acceptance question: does remembered experience improve later task outcomes compared with both a stateless system and a simple context baseline? The optional corner companion remains deferred until the underlying actions are useful and qualified.

Three questions deserve focused discussion in order. First, should early surprises appear only when someone opens the app or invokes an agent, or may Hippocampus occasionally interrupt with an evidence-backed suggestion? Second, should Today lead with where to resume or with the account of the day, while still providing both? Third, what source and project boundaries would make automatic agent delivery feel comfortable rather than invasive?

The answer should be tested through a small set of complete experiences, not another expanding list of sidebar labels. A successful product lets someone recover, understand, and continue their work with less effort while remaining in control of their memory.

## Sources

Live product pages were consulted on September 8, 2026. Undated vendor pages establish stated behavior, not independent verification or adoption. Papers establish results in their stated experimental settings. Older human-computer interaction work supports design reasoning, not current market sizing. The proposed priorities, examples, targets, and business choices are analytical judgments requiring product tests.

[^1]: Screenpipe. [Computer history and agents](https://screenpipe.com/). Undated current product page; stated capture, integration, and source-availability positioning.
[^2]: Dayflow. [Automatic time tracker for Mac](https://www.dayflow.so/). Undated current product page; journal, review, and processing choices.
[^3]: Shram Intelligence. [Minimi memory](https://www.projectminimi.com/memory). Undated current product page; Accessibility capture, Cotton/Melody, local storage, external processing, and vendor benchmark claims.
[^4]: Turnstone. [Product](https://myturnstone.ai/); Y Combinator, [Turnstone company page](https://www.ycombinator.com/companies/turnstone). Undated current positioning, not independent implementation verification.
[^5]: Microsoft Support. [Retrace your steps with Recall](https://support.microsoft.com/en-us/windows/ai/ai-features/retrace-your-steps-with-recall). Current feature and privacy documentation; hardware and availability conditions apply.
[^6]: Limitless. [Acquisition announcement and product FAQ](https://www.limitless.ai/). Announcement discusses December 2025 changes and 2026 access/support arrangements.
[^7]: Meta. [Personal superintelligence](https://www.meta.com/superintelligence/). Official vision statement; not evidence of an exact "Model Context Initiative" specification.
[^8]: Stack Overflow. [2025 Developer Survey: AI](https://survey.stackoverflow.co/2025/ai). Original survey findings; self-selected developer respondents and question-specific samples.
[^9]: Jaime Teevan, Christine Alvarado, Mark S. Ackerman, and David R. Karger. [The Perfect Search Engine Is Not Enough: A Study of Orienteering Behavior in Directed Search](https://www.microsoft.com/en-us/research/publication/perfect-search-engine-not-enough-study-orienteering-behavior-directed-search/). CHI, April 2004.
[^10]: Shamsi Iqbal and Eric Horvitz. [Disruption and Recovery of Computing Tasks: Field Study, Analysis, and Directions](https://www.microsoft.com/en-us/research/wp-content/uploads/2016/11/CHI_2007_Iqbal_Horvitz-1.pdf). CHI, April 2007.
[^11]: HeyClicky. [Trust and privacy](https://www.heyclicky.com/trust). Undated current data-handling statement.
[^12]: Mem0. [Introducing OpenMemory MCP](https://mem0.ai/blog/introducing-openmemory-mcp). Local memory infrastructure announcement.
[^13]: Mem0. [Mem0 MCP](https://docs.mem0.ai/platform/mem0-mcp). Current hosted platform documentation; distinct from local OpenMemory.
[^14]: Obsidian. [About](https://obsidian.md/about). Current principles and product model.
[^15]: Granola. [Series C announcement](https://www.granola.ai/blog/series-c). March 25, 2026; company-described expansion, not a retention study.
[^16]: Raycast. [Series B announcement](https://www.raycast.com/blog/series-b). September 25, 2024; historical product and distribution context, not current usage estimates.
[^17]: Timing. [Preferences](https://timingapp.com/help/preferences). Current documentation including idle handling.
[^18]: ActivityWatch. [Product and project](https://activitywatch.net/). Current activity-tracking scope.
[^19]: HeyClicky. [Changelog](https://www.heyclicky.com/changelog). Entries including June and July 2026; first-party descriptions of onboarding and responsiveness improvements.
[^20]: Screenpipe contributor report. [High resource usage, issue 183](https://github.com/screenpipe/screenpipe/issues/183). August 2024, closed historical issue; anecdotal failure mode, not current prevalence.
[^21]: Ruizhe Li et al. [When Your Agent Opens the Chat App: Agent-Controlled Search over Raw Chat Logs Rivals Structured Memory](https://arxiv.org/html/2608.12888v1). arXiv:2608.12888v1, August 13, 2026; ReFind methods and benchmark scope.
[^22]: Zhengjun Huang et al. [M3Exam: Benchmarking Multimodal Memory for Realistic User-Agent Interactions](https://arxiv.org/abs/2606.07402). arXiv:2606.07402v1, June 5, 2026.
[^23]: Jiazheng Kang et al. [Memory OS of AI Agent](https://arxiv.org/abs/2506.06326). arXiv:2506.06326v1, May 30, 2025.
[^24]: Zihao Cheng et al. [LifeBench: A Benchmark for Long-Horizon Multi-Source Memory](https://arxiv.org/abs/2603.03781). arXiv:2603.03781v1, March 4, 2026.
[^25]: Mohammad Tavakoli et al. [Beyond a Million Tokens: Benchmarking and Enhancing Long-Term Memory in LLMs](https://arxiv.org/abs/2510.27246). arXiv:2510.27246v2, revised February 21, 2026; BEAM and LIGHT.
[^26]: Anthropic. [Effective context engineering for AI agents](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents). September 29, 2025.
[^27]: Anthropic. [Claude Code hooks reference](https://code.claude.com/docs/en/hooks). Current SessionStart lifecycle and additional-context documentation.
[^28]: Anthropic. [Claude Code legal and compliance](https://code.claude.com/docs/en/legal-and-compliance). Current authentication and third-party product conditions; recheck before shipping a dependent integration.
[^29]: Hippocampus. [Status at audited source baseline](https://github.com/amyjainberkeley/hippocampus/blob/5bcb382afe7518962b9a4174c3a55dc3c0c6e433/docs/STATUS.md). Ledger updated September 7, 2026; installed build and open qualification status.
[^30]: Hippocampus. [DailyReview.swift](https://github.com/amyjainberkeley/hippocampus/blob/5bcb382afe7518962b9a4174c3a55dc3c0c6e433/apps/recall-ui/Sources/RecallUIKit/DailyReview.swift). Source at the audited baseline; deterministic observation kinds.
[^31]: Hippocampus. [extractive_author.rs](https://github.com/amyjainberkeley/hippocampus/blob/5bcb382afe7518962b9a4174c3a55dc3c0c6e433/core/brief/src/extractive_author.rs). Source at the audited baseline; extractive brief author.
[^32]: Hippocampus. [mci-brain-ffi/lib.rs](https://github.com/amyjainberkeley/hippocampus/blob/5bcb382afe7518962b9a4174c3a55dc3c0c6e433/adapters/macos/mci-brain-ffi/src/lib.rs). Source at the audited baseline; hit_json and snippet behavior.
[^33]: Hippocampus. [UserActivityReader.swift](https://github.com/amyjainberkeley/hippocampus/blob/5bcb382afe7518962b9a4174c3a55dc3c0c6e433/adapters/macos/MCICaptureHelper/Sources/MCICaptureHelperKit/Context/UserActivityReader.swift). Source at the audited baseline; input-idle observation, not attention measurement.
[^34]: Hippocampus. [SessionContextHook.swift](https://github.com/amyjainberkeley/hippocampus/blob/5bcb382afe7518962b9a4174c3a55dc3c0c6e433/apps/hippocampus/Sources/HippocampusKit/SessionContextHook.swift). Source at the audited baseline; bounded client context hook.
[^35]: Martin Kleppmann, Adam Wiggins, Peter van Hardenberg, and Mark McGranaghan / Ink & Switch. [Local-first software](https://www.inkandswitch.com/essay/local-first/). 2019; ownership, offline operation, and durable access principles.
[^36]: Hippocampus. [LICENSE](https://github.com/amyjainberkeley/hippocampus/blob/5bcb382afe7518962b9a4174c3a55dc3c0c6e433/LICENSE). Apache License 2.0 at the audited baseline; not a dependency or model-license audit.
[^37]: The Continual Learning Bench Team. [Continual Learning Bench 1.0](https://continual-learning-bench.com/news/cl-bench-1-0/). May 4, 2026; official release announcement.
[^38]: Parth Asawa et al. [Continual Learning Bench: Evaluating Frontier AI Systems in Real-World Stateful Environments](https://arxiv.org/html/2606.05661v1). arXiv:2606.05661v1, June 4, 2026; sections 4-6 cover metrics, results, and limitations. The proposed Hippocampus evaluation is an adaptation, not a reproduced result.
