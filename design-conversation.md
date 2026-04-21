I was exploring this design with a colleague. Here are some excerpts from our chat:

-- Their initial thoughts --

The most idiomatic Ruby approach is **not** to copy BenchBase’s Java shape literally.

BenchBase is built around an extensible benchmark testbed with workload-specific loaders, workers, and procedures, plus rate/mix control and stats collection. It also explicitly supports stored-procedure-oriented architectures and many benchmark families. ([Carnegie Mellon Database Group][1])

In Ruby, I’d model that as:

* **abstract protocols expressed as base classes + duck typing**
* **behavior sharing via modules**
* **plain objects for procedure calls and result events**
* **a small runtime that orchestrates connections, concurrency, timing, and reporting**

The mistake to avoid is building a big inheritance tree because BenchBase is Java. Ruby will get messy fast if you do that.

## The shape I’d use

Use five main concepts:

1. **Workload**
2. **Loader**
3. **Worker**
4. **Procedure**
5. **Result sink / reporter**

And keep them narrow.

### 1. Workload = the plugin boundary

A workload should just declare:

* what schema/data it needs
* what procedures exist
* how workers choose among procedures
* any workload-specific config

That gives you a clean boundary like BenchBase’s “available benchmarks” model, but Ruby-style. BenchBase itself is organized around many benchmark implementations under one framework. ([GitHub][2])

```ruby
module LoadForge
  class Workload
    def initialize(config:)
      @config = config
    end

    attr_reader :config

    def loaders
      raise NotImplementedError
    end

    def procedure_registry
      raise NotImplementedError
    end

    def worker_plan
      raise NotImplementedError
    end
  end
end
```

I would make workload objects mostly declarative.

---

## 2. Loaders = idempotent data population units

A loader should answer one question:

> “How do I prepare this dataset shard?”

Ruby-wise, that means **small command objects**, not giant service classes.

```ruby
module LoadForge
  class Loader
    def initialize(db:, config:, shard:)
      @db = db
      @config = config
      @shard = shard
    end

    def call
      raise NotImplementedError
    end
  end
end
```

Then per workload:

```ruby
class UserLoader < LoadForge::Loader
  def call
    db.transaction do
      # insert batch for this shard
    end
  end

  private

  attr_reader :db, :config, :shard
end
```

### Why this is idiomatic

Because in Ruby, a “thing that does work” is naturally a `#call` object. It composes cleanly, tests cleanly, and avoids over-formalizing.

### Practical advice

Make loaders:

* **idempotent where possible**
* **partition-aware**
* **independent from worker runtime**
* **connection-agnostic except for a passed DB/session handle**

Do **not** let loaders know about timing, reporting, or worker scheduling.

---

## 3. Procedures = plain transactional operations

For “procedures,” I would not use Ruby modules or metaprogramming first. I would use **one class per transactional operation**.

That keeps the benchmark definitions obvious.

```ruby
module LoadForge
  class Procedure
    def initialize(db:, rng:, config:, context: {})
      @db = db
      @rng = rng
      @config = config
      @context = context
    end

    def call
      raise NotImplementedError
    end
  end
end
```

Example:

```ruby
class NewOrder < LoadForge::Procedure
  def call
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)

    db.transaction do
      # SQL here
    end

    Result.success(
      name: "new_order",
      started_at_ns: started,
      finished_at_ns: Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
    )
  rescue => e
    Result.failure(
      name: "new_order",
      started_at_ns: started,
      finished_at_ns: Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond),
      error: e
    )
  end

  private

  attr_reader :db, :rng, :config, :context
end
```

### Why this works

BenchBase emphasizes transaction mixture control and stored-procedure-friendly design. Modeling each benchmark transaction as a first-class object maps well to that. ([Carnegie Mellon Database Group][1])

### What not to do

Don’t define procedures as giant hashes of lambdas unless the benchmark is extremely small. You’ll regret it once you need:

* per-procedure setup
* reusable parameter generation
* error classification
* custom metrics

---

## 4. Workers = runtime actors, not business logic containers

This is the big one.

A Worker should **not** contain benchmark semantics. It should only:

* acquire a session/connection
* ask a policy what to run next
* execute the chosen procedure
* publish results
* obey pacing/rate control/stop conditions

That separation matters because BenchBase’s framework value is largely in **rate control, transaction-mix control, and access distribution control**, not just procedure classes. ([Carnegie Mellon Database Group][1])

So make workers generic:

```ruby
module LoadForge
  class Worker
    def initialize(id:, db_pool:, procedure_selector:, result_sink:, clock:, stop_token:, rng:)
      @id = id
      @db_pool = db_pool
      @procedure_selector = procedure_selector
      @result_sink = result_sink
      @clock = clock
      @stop_token = stop_token
      @rng = rng
    end

    def run
      db_pool.with do |db|
        until stop_token.stop?
          proc_class, context = procedure_selector.next_procedure(worker_id: id, rng: rng)
          result = proc_class.new(db: db, rng: rng, config: context[:config], context: context).call
          result_sink << result
          procedure_selector.pace_after(result, clock: clock)
        end
      end
    end

    private

    attr_reader :id, :db_pool, :procedure_selector, :result_sink, :clock, :stop_token, :rng
  end
end
```

### Concurrency choice

In Ruby, the concurrency model should be an implementation detail of the runner:

* **threads** for DB I/O heavy cases
* **processes** if you need to bypass the GVL for CPU-heavy result aggregation
* maybe **Ractors** only if you enjoy pain

For a DB load framework, I’d start with **threads + one connection per worker**. That is the most practical Ruby baseline.

### Key principle

Workers are generic infrastructure. Procedures are workload-specific. Keep that line hard.

---

## 5. Results = immutable event objects

This is where Ruby apps often get sloppy.

Do **not** let procedures log directly, print directly, or mutate global stats.

Have them emit **immutable result objects**. Then let separate sinks aggregate.

```ruby
Result = Data.define(
  :name,
  :status,
  :started_at_ns,
  :finished_at_ns,
  :rows,
  :error_class,
  :error_message,
  :metadata
) do
  def latency_ns
    finished_at_ns - started_at_ns
  end

  def success?
    status == :ok
  end

  def self.success(name:, started_at_ns:, finished_at_ns:, rows: nil, metadata: {})
    new(name, :ok, started_at_ns, finished_at_ns, rows, nil, nil, metadata)
  end

  def self.failure(name:, started_at_ns:, finished_at_ns:, error:, metadata: {})
    new(name, :error, started_at_ns, finished_at_ns, nil, error.class.name, error.message, metadata)
  end
end
```

This gives you:

* low coupling
* multiple reporters
* replayable test traces
* easier percentiles / histograms / exports

BenchBase highlights microsecond-level latency/throughput stats and automatic rendering/reporting support. A structured event stream is the Ruby way to preserve that flexibility. ([Carnegie Mellon Database Group][1])

---

# What I’d do for the “interfaces”

Since Ruby doesn’t have first-class interfaces, the idiomatic answer is:

* use **small abstract base classes** where lifecycle matters
* use **duck typing** for optional capabilities
* use **modules** for shared behavior, not as your main contract system

For example:

```ruby
module TransactionalProcedure
  def with_timing(name)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
    yield
    Result.success(name: name, started_at_ns: started, finished_at_ns: Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond))
  rescue => e
    Result.failure(name: name, started_at_ns: started, finished_at_ns: Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond), error: e)
  end
end
```

Then include that in procedure classes.

That is a good Ruby use of mixins: shared mechanics, not pseudo-Java contracts.

---

# Recommended architecture

## A. Registry-based plugin system

Have each workload register itself:

```ruby
module LoadForge
  class Registry
    def initialize
      @workloads = {}
    end

    def register(name, workload_class)
      @workloads[name.to_s] = workload_class
    end

    def fetch(name)
      @workloads.fetch(name.to_s)
    end
  end
end
```

This is cleaner than scanning constants.

---

## B. Separate “selection policy” from worker

BenchBase cares about workload mix and rate control. Put that in its own object. ([Carnegie Mellon Database Group][1])

```ruby
class WeightedProcedureSelector
  def initialize(entries:, rate_limiter:)
    @entries = entries
    @rate_limiter = rate_limiter
  end

  def next_procedure(worker_id:, rng:)
    chosen = weighted_pick(rng)
    rate_limiter.before_request
    [chosen.proc_class, chosen.context]
  end

  def pace_after(_result, clock:)
  end
end
```

That lets you swap:

* closed-loop execution
* open-loop arrival process
* trace-driven replay
* hotspot/skew policies

without rewriting workers.

---

## C. Result sinks as append-only consumers

Examples:

* `HistogramSink`
* `JsonlSink`
* `StdoutProgressSink`
* `PrometheusSink`

Then a `FanoutSink`:

```ruby
class FanoutSink
  def initialize(*sinks)
    @sinks = sinks
  end

  def <<(result)
    @sinks.each { |s| s << result }
  end
end
```

That is a very Ruby-ish composition point.

---

## D. Keep DB adapter boundary thin

Don’t let procedures talk raw driver objects directly if you can avoid it.

Wrap common needs:

* transaction
* prepared query
* exec
* scalar
* batch insert

This gives you portability across:

* ActiveRecord connection
* Sequel
* PG / Mysql2 raw clients

For a benchmarking framework, I’d probably prefer **Sequel or thin raw adapters**, not ActiveRecord.

---

# My concrete recommendation for each piece

## Workers

Use **plain classes** with a `#run` method.
Generic runtime actors. No workload logic.

## Loaders

Use **command objects** with `#call`.
One loader per entity/table/data domain. Shardable and idempotent.

## Procedures

Use **one class per transaction type**, also with `#call`.
Return a `Result`, don’t mutate global counters.

## Results

Use **immutable value objects** plus separate sinks/aggregators.
That gives you clean latency accounting and multiple output formats.

---

# What I would avoid

## 1. Giant inheritance tree

Don’t build:

* `BaseWorker`
* `TransactionalWorker`
* `RateLimitedWorker`
* `TPCWorker`
* `ReadWriteWorker`

Ruby gets ugly when the behavior graph is really composition.

## 2. DSL first

It’s tempting to invent:

```ruby
procedure :new_order do
  txn mix: 45 do
    ...
  end
end
```

Nice demo, bad starting point.

Build the object model first. Add a DSL later only if it removes real repetition.

## 3. Global mutable stats

That will become a contention point and a correctness trap.

Use event emission + aggregation.

## 4. Mixing pacing and transaction logic

Workers and selectors handle pacing. Procedures do DB work. Keep them separate.

---

# If I were sketching the gem layout

```ruby
lib/
  load_forge/
    workload.rb
    loader.rb
    procedure.rb
    worker.rb
    registry.rb
    runner.rb
    result.rb
    result_sinks/
      fanout_sink.rb
      histogram_sink.rb
      jsonl_sink.rb
    selection/
      weighted_selector.rb
      trace_selector.rb
    pacing/
      closed_loop.rb
      poisson_arrivals.rb
    db/
      adapter.rb
      sequel_adapter.rb
workloads/
  tpcc/
    workload.rb
    loaders/
    procedures/
  ycsb/
    workload.rb
    loaders/
    procedures/
```

That’s boring in a good way.

---

# My opinionated bottom line

If you want this to feel idiomatic in Ruby:

* use **objects with `#call`** for loaders and procedures
* use **generic worker runtime classes**
* use **immutable result events**
* use **composition objects** for pacing, selection, and reporting
* use **modules only for shared mechanics**
* use **base classes sparingly for lifecycle contracts**

So the mental model becomes:

> **Workload declares. Worker executes. Procedure does one transaction. Loader seeds data. Result reports what happened.**

That is the cleanest Ruby translation of a BenchBase-like framework.

If you want, I can sketch a minimal Ruby codebase for this with one example workload and a simple threaded runner.

[1]: https://db.cs.cmu.edu/projects/benchbase/ "BenchBase - Carnegie Mellon Database Group"
[2]: https://github.com/cmu-db/benchbase/wiki "Home · cmu-db/benchbase Wiki · GitHub"

-- My response --

This is great. I want to create synthetic webapps for several of the benchbase workloads in different languages and test an LLM's ability to optimize source code, indicies, and database configuration based on collected statistics. This means I'd want this workload to drive things at the web layer and support data loading through some sort of contract in the webapps themselves (Eg, if it were a Rails app, the rails app would create the schema as specified and provide a way to load a dataset that met the interface for this load runner -- same for an Express app, or a Dropwizard/JDBI app). What could that look like?

-- Response --

What you’re proposing is actually more interesting than “BenchBase but in Ruby.”
You’re designing a **closed-loop system where the workload, the app, and the optimizer (LLM) all interact through observable contracts**.

If you don’t get the contracts right, this turns into a pile of adapters. If you do, it becomes a reusable research platform.

Let me push you toward a structure that will hold up once you add multiple languages and LLM-driven mutation.

---

# The core idea (don’t skip this)

You need to **decouple three things cleanly**:

1. **Workload semantics** (TPC-C, YCSB, etc.)
2. **Execution surface** (web app in Rails / Express / Dropwizard)
3. **Optimization loop** (LLM modifying code/config/schema)

The mistake would be letting the workload runner “know” anything about Rails or Express.

Instead:

> The webapp becomes a **black-box system with a standard control + data plane API**

---

# The contract: treat the webapp like a testable appliance

Every app—Rails, Node, Java—implements the same interface.

Think of it as:

## 1. Control Plane API (admin / orchestration)

This is how your runner sets up and mutates the system.

```http
POST /__bench/setup
POST /__bench/load
POST /__bench/reset
GET  /__bench/schema
POST /__bench/config
GET  /__bench/health
```

### Example

```json
POST /__bench/load
{
  "scale_factor": 10,
  "seed": 42,
  "shards": 4
}
```

This replaces your “Loader” abstraction.
The app owns its data generation because:

👉 It knows its ORM, schema quirks, migrations, etc.

---

## 2. Data Plane API (the actual workload)

This is what workers hit.

Instead of calling procedures directly, you define **HTTP endpoints that map 1:1 to workload procedures**:

```http
POST /api/new_order
POST /api/payment
GET  /api/order_status
```

These are your “Procedures,” but now implemented in each framework.

Important:

* The runner **does not care how these are implemented**
* It only cares about:

  * latency
  * success/failure
  * optional metadata

---

## 3. Observability Plane (critical for your LLM goal)

This is where most people get it wrong.

You need **structured, machine-readable stats**, not logs.

```http
GET /__bench/stats
GET /__bench/metrics
GET /__bench/traces
```

### Example response

```json
{
  "db": {
    "queries": [
      {
        "fingerprint": "SELECT * FROM orders WHERE id = ?",
        "calls": 10234,
        "mean_ms": 3.2,
        "p95_ms": 8.1,
        "rows": 1.0
      }
    ]
  },
  "app": {
    "endpoints": {
      "/api/new_order": {
        "p50_ms": 12,
        "p95_ms": 45,
        "errors": 0.01
      }
    }
  }
}
```

This is the **input to your LLM**.

---

# How your Ruby runner fits in now

Your runner becomes:

* a **traffic generator**
* a **control-plane orchestrator**
* a **metrics collector**

NOT a procedure executor anymore.

So your previous abstractions shift slightly:

## Workers → HTTP clients

```ruby
class Worker
  def run
    until stop?
      endpoint = selector.next
      result = client.call(endpoint)
      sink << result
    end
  end
end
```

## Procedures → just names + payload generators

```ruby
Procedure = Data.define(:name, :method, :path, :payload_generator)
```

No DB logic here anymore.

---

# The key design decision: who owns data generation?

You already leaned the right way:

> “the rails app would create the schema and load the dataset”

Yes. Keep it that way.

### Why?

Because otherwise you’ll fight:

* ORM differences
* migrations
* connection pooling
* transaction semantics
* framework conventions

Instead, define a **data loading contract**, not an implementation.

---

# Define a “Workload Spec”

This is the glue between runner and apps.

```json
{
  "name": "tpcc",
  "scale_parameters": {
    "warehouses": "int"
  },
  "endpoints": [
    {
      "name": "new_order",
      "method": "POST",
      "path": "/api/new_order",
      "weight": 45
    }
  ]
}
```

Each app must:

* implement endpoints
* implement `/__bench/load` that produces equivalent data

---

# Cross-language consistency problem (this will bite you)

If you want fair comparisons:

You must ensure:

* same schema shape
* same data distributions
* same randomness model

So don’t leave this fully open-ended.

## Solution: shared reference generator

Have a **canonical data model + generator spec**:

* either:

  * a shared library (hard across languages)
  * OR
  * a deterministic spec (better)

Example:

```json
{
  "table": "orders",
  "columns": {
    "id": "sequence",
    "user_id": "uniform(1, 100000)",
    "amount": "normal(50, 10)"
  }
}
```

Each app implements this spec.

---

# LLM optimization loop (this is where it gets interesting)

Now you can close the loop:

### 1. Run workload

→ collect stats

### 2. Feed stats + code to LLM

### 3. LLM outputs changes:

* index suggestions
* query rewrites
* config changes
* code patches

### 4. Apply changes via control plane

```http
POST /__bench/apply_patch
POST /__bench/add_index
POST /__bench/config
```

### 5. Reset + rerun

---

# What you should standardize (non-negotiable)

If you want meaningful results, lock these down:

## 1. Endpoint semantics

* request/response shapes
* error behavior
* idempotency expectations

## 2. Timing model

* client-side latency measurement (runner)
* optional server-side breakdown

## 3. DB visibility

* pg_stat_statements / MySQL performance_schema equivalent
* normalized query fingerprints

## 4. Reset behavior

You need:

```http
POST /__bench/reset
```

That guarantees:

* same initial state
* no leftover indexes unless intentional

---

# Rails / Express / Dropwizard implementations

Here’s what changes per framework:

## Rails

* `/__bench/load` → seeds or custom loader service
* endpoints → controllers
* stats → ActiveSupport instrumentation + DB adapter hooks

## Express

* loader → script + endpoint
* endpoints → route handlers
* stats → middleware + DB client wrapping

## Dropwizard / JDBI

* loader → DAO batch inserts
* endpoints → resources
* stats → metrics + interceptors

The key is: **they all expose the same HTTP contract**

---

# One design choice I’d challenge you on

You said:

> “support data loading through some sort of contract in the webapps themselves”

That’s correct—but incomplete.

You also need:

> a way to **extract structured query-level behavior consistently**

Otherwise your LLM is guessing.

So I’d require:

```http
GET /__bench/query_stats
```

with normalized fingerprints.

---

# If I were building this from scratch

I’d structure it like this:

## Runner (Ruby)

* workload spec loader
* HTTP workers
* result aggregation
* experiment orchestration

## App (per language)

* implements control + data + observability APIs
* owns schema + data generation

## Shared

* workload spec
* data generation spec
* metrics schema

---

# Bottom line

What you’re building is not just a load tester.

It’s:

> **a standardized, language-agnostic performance sandbox for evaluating optimization intelligence**

To make it work:

* Treat apps as **black-box systems with a strict API**
* Move **all DB logic into the app layer**
* Keep runner focused on **traffic + measurement**
* Make observability **structured and query-aware**
* Define **deterministic data generation contracts**

---

If you want, next step I’d suggest is:

👉 pick one workload (TPC-C or a simplified YCSB)
👉 define the exact HTTP + stats contract
👉 implement it in Rails first

Then we can stress-test whether the abstraction actually holds before you multiply it across languages.

Here’s a **clean, Codex-ready design doc** that captures what you’re building, but in a way that will actually produce a usable system (not a research-y blob).

I’ve structured it like something you can drop directly into a repo as `DESIGN.md`.

---

# **Design Doc: Cross-Language Synthetic Webapp Benchmarking + LLM Optimization Framework**

## 1. Overview

This project is a **language-agnostic benchmarking and optimization platform** for database-backed web applications.

It combines:

* Synthetic workloads (inspired by BenchBase)
* Realistic web application implementations (Rails, Express, Dropwizard, etc.)
* A load generation + measurement system
* A closed-loop optimization system powered by LLMs

### Key Idea

Instead of benchmarking databases directly, we benchmark **full-stack web applications** under controlled workloads and allow an LLM to:

* analyze performance data
* modify application code, indexes, and configuration
* iteratively improve performance

---

## 2. Goals

### Primary Goals

* Provide **consistent workload execution across multiple languages/frameworks**
* Enable **apples-to-apples performance comparisons**
* Generate **structured performance data for LLM consumption**
* Support **automated optimization loops**

### Non-Goals

* Not a general-purpose load testing tool
* Not tied to a single framework or DB
* Not focused on perfect benchmark fidelity (initially)

---

## 3. High-Level Architecture

```
+---------------------+
|   Ruby Runner       |
|---------------------|
| - Workload Driver   |
| - HTTP Workers      |
| - Metrics Collector |
| - Orchestrator      |
+----------+----------+
           |
           | HTTP
           v
+---------------------------+
|   Web App (Rails/Node/...)|
|---------------------------|
| Control Plane API         |
| Data Plane API            |
| Observability API         |
+---------------------------+
           |
           v
+---------------------------+
|        Database           |
+---------------------------+

+---------------------------+
| LLM Optimization Loop     |
|---------------------------|
| - Analyze stats           |
| - Propose changes         |
| - Apply patches           |
+---------------------------+
```

---

## 4. Core Design Principles

### 4.1 Black-Box Application Model

Each web app is treated as a **black box with a strict API contract**.

The runner:

* does not know the internal implementation
* only interacts via HTTP

---

### 4.2 Separation of Concerns

| Component | Responsibility                                 |
| --------- | ---------------------------------------------- |
| Runner    | Traffic generation, orchestration, measurement |
| Web App   | Business logic, schema, data generation        |
| Database  | Storage + execution                            |
| LLM       | Optimization decisions                         |

---

### 4.3 Deterministic Workloads

Workloads must be:

* reproducible (seeded RNG)
* comparable across implementations
* statistically stable

---

## 5. Web App Contract (Critical)

Each web app MUST implement three APIs:

---

## 5.1 Control Plane API (Setup + Mutation)

Used by the runner to prepare and modify the system.

### Endpoints

```http
POST /__bench/setup
POST /__bench/load
POST /__bench/reset
POST /__bench/config
POST /__bench/apply_patch
GET  /__bench/health
GET  /__bench/schema
```

### Responsibilities

* Create schema
* Load dataset
* Reset state
* Apply configuration changes
* Apply LLM-generated patches (optional)

---

### Example

```json
POST /__bench/load
{
  "scale_factor": 10,
  "seed": 42
}
```

---

## 5.2 Data Plane API (Workload Execution)

Implements workload-specific endpoints.

Each endpoint corresponds to a **transaction type** (like BenchBase procedures).

### Example (TPC-C-like)

```http
POST /api/new_order
POST /api/payment
GET  /api/order_status
```

### Requirements

* Deterministic input generation (from runner)
* Consistent response semantics
* Proper error handling

---

## 5.3 Observability API (LLM Input)

This is **non-negotiable** for your use case.

### Endpoints

```http
GET /__bench/stats
GET /__bench/query_stats
GET /__bench/metrics
```

---

### Example Response

```json
{
  "app": {
    "endpoints": {
      "/api/new_order": {
        "p50_ms": 12,
        "p95_ms": 45,
        "error_rate": 0.01
      }
    }
  },
  "db": {
    "queries": [
      {
        "fingerprint": "SELECT * FROM orders WHERE id = ?",
        "calls": 10234,
        "mean_ms": 3.2,
        "p95_ms": 8.1
      }
    ]
  }
}
```

---

### Why This Matters

BenchBase emphasizes precise latency + throughput measurement and workload control ([Carnegie Mellon Database Group][1])

But your system adds:

👉 **structured introspection for optimization**

---

## 6. Workload Specification

Workloads are defined declaratively.

```json
{
  "name": "tpcc",
  "seed": 42,
  "endpoints": [
    {
      "name": "new_order",
      "method": "POST",
      "path": "/api/new_order",
      "weight": 45
    },
    {
      "name": "payment",
      "method": "POST",
      "path": "/api/payment",
      "weight": 43
    }
  ]
}
```

---

## 7. Runner Design (Ruby)

The runner is a **multi-threaded HTTP load generator**, similar in spirit to BenchBase’s client-side driver ([GitHub][2])

---

### 7.1 Workers

Workers simulate concurrent users.

```ruby
class Worker
  def run
    until stop?
      endpoint = selector.next
      result = client.call(endpoint)
      sink << result
    end
  end
end
```

---

### 7.2 Procedure Representation

```ruby
Procedure = Data.define(
  :name,
  :method,
  :path,
  :payload_generator
)
```

---

### 7.3 Result Model

Immutable event objects:

```ruby
Result = Data.define(
  :name,
  :status,
  :latency_ns,
  :error
)
```

---

### 7.4 Load Control

Support:

* weighted mixes
* rate limiting
* open vs closed loop

BenchBase highlights:

* rate control
* transaction mix control
* workload phases ([Carnegie Mellon Database Group][1])

---

## 8. Data Loading Strategy

### Key Decision

**Data loading is owned by the web app**

---

### Why

Avoids:

* ORM mismatch
* schema drift
* migration complexity

---

### Contract

```http
POST /__bench/load
```

App must:

* generate dataset
* ensure deterministic distribution
* support scaling

---

## 9. LLM Optimization Loop

This is the differentiator.

---

### Loop

1. Run workload
2. Collect stats
3. Feed to LLM
4. LLM proposes:

   * indexes
   * query changes
   * config updates
   * code patches
5. Apply changes
6. Reset + rerun

---

### Control Endpoints

```http
POST /__bench/apply_patch
POST /__bench/config
POST /__bench/add_index
```

---

### Output Example

```json
{
  "action": "add_index",
  "sql": "CREATE INDEX idx_orders_user_id ON orders(user_id)"
}
```

---

## 10. Cross-Language Implementations

Each framework must implement the same contract:

---

### Rails

* Control: controller namespace `/__bench`
* Data: standard controllers
* Stats: ActiveSupport + DB adapter hooks

---

### Express (Node.js)

* Control: routes + scripts
* Data: route handlers
* Stats: middleware + DB wrapper

---

### Dropwizard / JDBI

* Control: admin endpoints
* Data: resources
* Stats: metrics + interceptors

---

## 11. Observability Requirements

To support meaningful optimization:

### MUST HAVE

* query fingerprints
* per-endpoint latency
* error rates
* throughput

---

### SHOULD HAVE

* query plans
* row counts
* lock wait times

---

## 12. Reset & Reproducibility

```http
POST /__bench/reset
```

Guarantees:

* clean DB state
* deterministic dataset
* controlled experiment environment

---

## 13. Risks & Challenges

### 13.1 Cross-language consistency

* schema drift
* data distribution mismatch

### 13.2 Observability gaps

* different DBs expose different stats

### 13.3 LLM instability

* non-deterministic improvements
* regressions

### 13.4 Benchmark validity

Synthetic workloads may diverge from real-world behavior
(known issue in benchmarking research ([VLDB][3]))

---

## 14. MVP Scope

Start with:

* One workload (simplified TPC-C or YCSB)
* One app (Rails)
* One DB (Postgres)
* Basic stats:

  * latency
  * query frequency
* Simple LLM loop:

  * index suggestions only

---

## 15. Future Extensions

* Multi-DB support
* Query plan introspection
* Trace replay
* Multi-phase workloads
* Distributed load generation
* Auto-generated workloads (LLM-driven)

---

# Final Summary

This system is:

> **A standardized performance sandbox for evaluating and improving database-backed applications using LLMs**

Key ideas:

* Web apps implement a **strict HTTP contract**
* Runner is **stateless + generic**
* Observability is **structured + machine-readable**
* LLM operates in a **closed optimization loop**

---

If you want next step:

I’d have Codex generate:

1. the Ruby runner skeleton
2. a minimal Rails app implementing `/__bench/*`
3. one endpoint (`/api/new_order`)

That will tell you immediately whether this design actually holds under real friction.

[1]: https://db.cs.cmu.edu/projects/benchbase/?utm_source=chatgpt.com "BenchBase"
[2]: https://github.com/cmu-db/benchbase?utm_source=chatgpt.com "cmu-db/benchbase: Multi-DBMS SQL Benchmarking ..."
[3]: https://www.vldb.org/pvldb/vol18/p3883-fan.pdf?utm_source=chatgpt.com "Workload Synthesizer with Real Statistics for Cloud ..."

-- A scope correction from me --

I'm planning to implement this observability API at the database engine layer and as part of its control plane, so we don't need to bake it into each implementation. I'm also concerned that requiring the implementation to provide those __bench routes might throw off the LLM and give it more hints than it should have if were reading the code in the same repo. I'm ok with adapters, though - especially if we can locate those adapters in separate "wrapper" repos (or mono-repos). Let's explore this a little and then update the design doc.

-- Response --

Yes — that changes the design in a good way.

Your two concerns are real:

1. **Observability should not be reimplemented in every app**
2. **Benchmark-only routes inside the app repo can contaminate the optimization task**

If the LLM can read the same repo it is optimizing, a bunch of `__bench/*` code is basically a neon sign saying “this is synthetic benchmark harness code.” That can skew behavior, encourage overfitting, and waste context on non-product code.

The cleaner model is:

> **The app repo should look as close to a normal app as possible.**
> Benchmark control, loading orchestration, and observability should live in **external adapters and infrastructure**.

That means shifting from an **in-app benchmark API** to a **sidecar / wrapper / control-plane adapter model**.

---

# What I’d change conceptually

## Old model

The app itself exposes:

* control plane routes
* workload routes
* observability routes

## New model

The app exposes only:

* its normal application surface
* optionally a very small, generic seed/setup contract if absolutely necessary

Everything else lives outside:

* **Runner** drives HTTP traffic
* **Wrapper / adapter** handles setup, load orchestration, and resets
* **DB control plane** exposes query stats, plans, engine config, and reset support
* **optional repo wrapper** provides framework-specific integration glue in a separate repo

This is much better for your use case.

---

# The architecture I’d recommend

There are now **four layers** instead of three:

1. **Application repo**
2. **Benchmark adapter repo**
3. **Database engine + control plane**
4. **Runner / experiment orchestrator**

## 1. Application repo

Contains:

* the actual app
* schema/migrations
* normal business endpoints
* ordinary framework conventions

Should ideally **not** contain:

* benchmark admin routes
* benchmark stats endpoints
* benchmark patch handlers
* synthetic control-plane code

This is the thing the LLM should inspect and optimize.

---

## 2. Benchmark adapter repo

Contains framework-specific glue, but separate from the app being optimized.

Examples:

* `rails-bench-adapter`
* `express-bench-adapter`
* `dropwizard-bench-adapter`

Responsibilities:

* bootstrapping app for benchmark runs
* invoking schema setup / migrations
* invoking seed or bulk-load contracts
* mediating reset lifecycle
* possibly injecting benchmark middleware outside the app repo if needed
* translating generic workload specs into framework-native loader calls

This repo is allowed to know benchmark semantics. The app repo is not.

---

## 3. Database engine + control plane

This becomes the canonical source of:

* query fingerprints
* latency distributions
* row counts
* plans
* lock contention
* config settings
* index metadata
* schema inspection
* reset / snapshot / restore primitives, if the engine supports them

That is the right place for observability.

It gives you:

* cross-framework consistency
* less per-app instrumentation
* lower chance of app-specific observability bugs
* better parity when comparing Rails vs Express vs Java

This is a strong move.

---

## 4. Runner / experiment orchestrator

Still responsible for:

* traffic generation
* workload mix
* timing
* latency measurement
* experiment sequencing
* collecting stats from DB control plane + app-level HTTP responses
* passing results into the LLM loop

---

# The key tradeoff: how does data loading happen now?

If you remove `POST /__bench/load` from the app, you still need a way to create equivalent datasets.

There are really three viable options.

## Option A: adapter invokes native app commands

For example:

* Rails: `bin/rails db:migrate`, `bin/rails runner ...`
* Express: custom Node script
* Dropwizard: CLI / admin task / bootstrap class

The adapter repo owns these commands and can call into the app through ordinary framework extension points.

### Pros

* keeps benchmark code out of main app routes
* feels natural per framework
* lets app own schema/data semantics

### Cons

* some benchmark logic still needs to exist somewhere the app can call
* cross-language parity requires discipline

This is probably the best starting point.

---

## Option B: external canonical dataset generator + direct DB load

The adapter or runner generates data according to workload spec and writes directly to DB.

### Pros

* maximum comparability
* app stays very clean
* deterministic at the dataset level

### Cons

* bypasses app/ORM semantics
* may fail to reflect realistic schema creation paths
* annoying across DBs and frameworks
* fragile if app schema evolves

I would not start here unless your real goal is DB-only evaluation masquerading as app benchmarking.

---

## Option C: app exposes a tiny seed/setup library contract, not routes

For example, each app provides code like:

* Rails: `Bench::Setup.load(scale:, seed:)`
* Node: exported module function
* Java: bootstrap interface

The adapter invokes it from outside the app via framework-native execution.

### Pros

* benchmark hooks exist, but not as HTTP routes
* easier to standardize than ad hoc scripts
* avoids polluting the user-facing app surface

### Cons

* still introduces benchmark-aware code into app repo
* the LLM may still see it if reading the repo

This is better than routes, but worse than fully externalized wrappers if you care about contamination.

---

# My recommendation

Use a hybrid:

## For app setup/loading

Use **adapter-owned orchestration** that calls:

* migrations
* framework-native seed/bootstrap entrypoints
* optional benchmark seed libraries only when unavoidable

## For observability

Use **DB engine control plane only** as the source of truth.

## For workload traffic

Use **normal app endpoints only**.

That keeps the app looking like a real app.

---

# Important distinction: app-under-test vs benchmark harness

You should explicitly define two repo classes:

## App-under-test repo

What the LLM is allowed to optimize.

Contains:

* source code
* ORM models / DAOs
* migrations
* app config
* normal tests

## Harness / adapter repo

What the LLM may or may not see, depending on experiment design.

Contains:

* workload specs
* adapter code
* runner configuration
* benchmark lifecycle commands
* framework boot glue

This separation is useful not just architecturally, but experimentally.

You can run different evaluation modes:

* **blind app optimization**: LLM sees only app repo
* **app + harness optimization**: LLM sees app and wrapper
* **DB-only optimization**: LLM sees stats + schema but not app code
* **full-stack optimization**: LLM sees everything

That’s a much richer research setup.

---

# What the adapter contract could look like

Instead of HTTP `__bench` routes, define an out-of-band **Adapter Capability Contract**.

Each adapter implements methods like:

* `prepare_environment`
* `apply_schema`
* `load_dataset(scale:, seed:)`
* `reset_state`
* `start_app`
* `stop_app`
* `base_url`
* `health_check`
* `collect_app_metadata`

This can be expressed as a process contract, CLI contract, or RPC contract.

## Example CLI-style contract

```bash
bench-adapter prepare
bench-adapter migrate
bench-adapter load --scale 10 --seed 42
bench-adapter reset
bench-adapter start
bench-adapter stop
bench-adapter health
bench-adapter base-url
```

This is much better than embedding `/__bench/*` in the app.

The runner just shells out to adapter commands or talks to a lightweight adapter service.

---

# Where should schema creation live?

You said:

> if it were a Rails app, the rails app would create the schema as specified

That still holds.

But now the adapter should invoke **ordinary framework schema workflows** instead of special benchmark routes.

Examples:

## Rails

* `bin/rails db:drop db:create db:migrate`
* `bin/rails runner AdapterSeed.load(scale: ..., seed: ...)`

## Express

* migration CLI
* standalone seed script invoked by adapter

## Dropwizard/JDBI

* Flyway/Liquibase migration step
* seed bootstrap class or admin task invoked externally

That keeps the schema lifecycle honest.

---

# Observability at the DB engine layer: what this buys you

This is one of the best parts of the redesign.

If the DB engine control plane provides:

* statement fingerprints
* call counts
* latency histograms
* plans
* lock waits
* temp usage
* reads/writes
* index hit/miss
* config snapshot
* schema snapshot

then the runner no longer needs app-specific stats endpoints.

The app only needs to return normal HTTP responses. The rest comes from:

* runner-side HTTP timing
* DB control-plane stats

That’s much cleaner.

## Subtle benefit

It also makes the optimization target more realistic.

Real production tuning usually involves:

* app source
* DB stats
* config
* schema/indexes

not “special benchmark middleware inside the app.”

---

# One thing to watch out for

If you move observability entirely to the DB engine layer, you lose some app-layer visibility unless you deliberately preserve it.

Examples:

* endpoint → query mapping
* per-request trace correlation
* request payload classification
* cache hits/misses above DB
* ORM-level N+1 context

You probably still want some of this eventually.

But I would not force it into the app repo.

## Better approach

Use wrapper-owned or runtime-injected instrumentation where possible:

* reverse proxy logs
* framework middleware mounted by adapter
* OpenTelemetry auto-instrumentation
* DB session tags / comments injected by wrapper if supported

That gives you request-to-query linkage without polluting the main source tree too much.

---

# A better workload model now

Because the app won’t expose special procedure routes just for benchmarking, the workload spec should describe **normal application actions**.

Example:

```json
{
  "name": "tpcc-web",
  "actions": [
    {
      "name": "new_order",
      "method": "POST",
      "path": "/orders",
      "weight": 45,
      "payload_model": "tpcc_new_order"
    },
    {
      "name": "payment",
      "method": "POST",
      "path": "/payments",
      "weight": 43,
      "payload_model": "tpcc_payment"
    }
  ]
}
```

That’s stronger than naming them “procedures” now. These are **HTTP actions** mapped to workload semantics.

---

# What I’d change in the design doc

Below is the updated design doc in a more refined form.

---

# Design Doc: Cross-Language Synthetic Webapp Benchmarking + LLM Optimization Framework

## 1. Overview

This project is a language-agnostic benchmarking and optimization platform for database-backed web applications.

It combines:

* synthetic workloads inspired by BenchBase-style transaction mixes
* realistic web application implementations in multiple frameworks/languages
* a generic load generation and experiment runner
* database-engine-level observability and control-plane introspection
* a closed-loop LLM optimization workflow

The system is designed so that the **application under test remains as close as possible to a normal application repo**, while benchmark lifecycle and observability concerns are externalized into adapters and infrastructure.

---

## 2. Primary Goals

* Benchmark full-stack web applications rather than direct DB procedure calls
* Compare equivalent workloads across multiple frameworks and languages
* Collect structured performance signals suitable for LLM-driven optimization
* Keep benchmark harness code out of the main application repo when possible
* Support repeatable closed-loop experiments involving code, index, and config changes

---

## 3. Non-Goals

* General-purpose load testing for arbitrary production systems
* Perfect fidelity to official benchmark suites in the initial phase
* Requiring each application to embed benchmark-specific control or observability routes
* Relying on application-specific stats implementations as the primary observability source

---

## 4. High-Level Architecture

```text
+----------------------------+
| Runner / Orchestrator      |
|----------------------------|
| - workload execution       |
| - HTTP workers             |
| - latency measurement      |
| - experiment control       |
| - LLM loop integration     |
+-------------+--------------+
              |
              | normal HTTP traffic
              v
+----------------------------+
| App Under Test            |
|----------------------------|
| - normal routes           |
| - app code                |
| - schema/migrations       |
| - framework conventions   |
+-------------+--------------+
              |
              v
+----------------------------+
| Database Engine            |
|----------------------------|
| - execution               |
| - query stats             |
| - plans                   |
| - config/state            |
| - control plane           |
+----------------------------+

+----------------------------+
| Adapter / Wrapper Layer    |
|----------------------------|
| - setup                    |
| - migrate                  |
| - seed/load                |
| - reset                    |
| - boot/stop app            |
| - optional instrumentation |
+----------------------------+
```

---

## 5. Core Principles

### 5.1 App-under-test should look normal

The application repo should resemble a realistic application codebase. Benchmark-specific lifecycle and observability concerns should be kept outside the repo when practical.

### 5.2 Benchmark harness lives outside the app

Framework-specific setup, reset, load, and orchestration logic should live in separate adapter or wrapper repos, not as special routes inside the application.

### 5.3 Database control plane is the primary observability source

Structured query-level metrics, plans, configuration, and engine state should be collected at the database layer rather than reimplemented per framework.

### 5.4 Normal app surface is the workload surface

Benchmark traffic should hit ordinary application endpoints rather than synthetic benchmark-only endpoints where possible.

### 5.5 Reproducibility matters

Datasets, workload mixes, RNG seeds, and reset behavior must be deterministic enough to support repeated optimization loops.

---

## 6. System Components

### 6.1 App Under Test

The application repo contains:

* business logic
* normal HTTP endpoints
* schema/migrations
* application configuration
* framework-native bootstrapping

It should ideally not contain:

* benchmark-only `__bench` routes
* benchmark-specific stats endpoints
* patch application endpoints
* synthetic admin controllers solely for benchmark control

### 6.2 Adapter / Wrapper

Each framework gets an adapter maintained outside the app repo.

Examples:

* rails benchmark adapter
* express benchmark adapter
* dropwizard benchmark adapter

Responsibilities:

* prepare environment
* run migrations/schema setup
* perform dataset load through framework-native mechanisms
* reset application/database state
* start and stop the app
* perform health checks
* optionally inject runtime instrumentation outside the app repo

### 6.3 Runner / Orchestrator

Responsibilities:

* execute workload mix
* generate HTTP traffic
* measure latency and errors at client side
* sequence experiment phases
* call adapter lifecycle operations
* collect DB control-plane stats
* package evidence for LLM optimization

### 6.4 Database Engine + Control Plane

Responsibilities:

* expose query fingerprints and latency summaries
* expose plans and schema metadata
* expose config and index metadata
* support reset/snapshot hooks where possible
* serve as the primary introspection surface for optimization

---

## 7. Adapter Contract

Instead of benchmark routes embedded in the app, adapters implement an external lifecycle contract.

### Required capabilities

* `prepare_environment`
* `apply_schema`
* `load_dataset(scale:, seed:)`
* `reset_state`
* `start_app`
* `stop_app`
* `health_check`
* `base_url`

### Possible implementation styles

* CLI commands
* local RPC service
* container entrypoints
* test harness scripts

### Example CLI contract

```bash
bench-adapter prepare
bench-adapter migrate
bench-adapter load --scale 10 --seed 42
bench-adapter reset
bench-adapter start
bench-adapter stop
bench-adapter health
bench-adapter base-url
```

The runner should depend on this contract, not on framework-specific internals.

---

## 8. Workload Model

A workload is defined as a set of application actions, not DB procedures directly.

Each action includes:

* name
* HTTP method
* path
* mix weight
* payload generator or payload model
* optional validation rules

### Example

```json
{
  "name": "tpcc-web",
  "seed": 42,
  "actions": [
    {
      "name": "new_order",
      "method": "POST",
      "path": "/orders",
      "weight": 45,
      "payload_model": "tpcc_new_order"
    },
    {
      "name": "payment",
      "method": "POST",
      "path": "/payments",
      "weight": 43,
      "payload_model": "tpcc_payment"
    }
  ]
}
```

The runner uses this spec to drive HTTP traffic. The app implements normal routes that satisfy the intended semantics.

---

## 9. Data Loading Strategy

### Preferred approach

The adapter invokes framework-native setup and load mechanisms outside the app’s public HTTP surface.

Examples:

* Rails migrations + runner-invoked seed/setup code
* Express migration + seed scripts
* Dropwizard migration tool + bootstrap loader

### Rationale

This preserves realistic schema and application ownership while avoiding benchmark-only app routes.

### Constraint

Cross-language parity requires a deterministic workload/data specification. The same scale factor and seed should produce equivalent distributions across implementations, even if the internal load mechanism differs.

---

## 10. Observability Model

### Primary observability source

The database engine control plane.

### Must-have signals

* normalized query fingerprints
* call counts
* latency summaries or histograms
* rows read/written where available
* index metadata
* configuration snapshot
* plan access where available
* lock/contention or wait indicators where available

### Runner-collected signals

* end-to-end request latency
* HTTP status/error rate
* throughput
* workload phase timing

### Optional secondary observability

If needed later, app/request-level visibility can be added through wrapper-owned instrumentation rather than source-level benchmark endpoints. Examples:

* reverse proxy logs
* OpenTelemetry auto-instrumentation
* runtime-injected middleware
* DB session tagging or comments

---

## 11. LLM Optimization Loop

### Inputs

* app source code
* workload spec
* DB control-plane stats
* runner latency/error summaries
* optional plans/config snapshots

### Outputs

* code changes in app repo
* index changes
* DB config changes
* sometimes workload-aware recommendations

### Loop

1. prepare/reset environment via adapter
2. apply schema and load dataset
3. run workload
4. collect runner-side and DB-side evidence
5. ask LLM for optimization changes
6. apply code/config/index changes
7. rerun experiment and compare

### Important experimental mode

The system should support controlling what the LLM is allowed to see:

* app repo only
* app repo + DB stats
* app repo + adapter repo
* full system context

This is useful for evaluating whether benchmark harness knowledge leaks into optimization quality.

---

## 12. Reset and Reproducibility

A benchmark run must be restartable from a known state.

This includes:

* deterministic schema version
* deterministic dataset generation
* deterministic workload seed
* controlled config state
* no leftover indexes unless intentionally preserved

Reset should be mediated by the adapter and, where useful, by DB control-plane primitives such as snapshot/restore.

---

## 13. Risks and Design Tensions

### 13.1 Cross-language equivalence

Different frameworks may implement slightly different semantics or data generators. This can distort comparisons.

### 13.2 Loss of app-layer context

DB-layer observability is strong for query tuning but weaker for request-to-query attribution unless additional instrumentation is added.

### 13.3 Adapter creep

Too much framework-specific logic in adapters can become hard to maintain. Keep adapter contracts narrow.

### 13.4 Benchmark contamination

If benchmark-specific code leaks into app repos, the LLM may overfit to the harness rather than optimize the application naturally.

### 13.5 Optimization scope ambiguity

You need clear rules for whether the LLM may change only app code, or also migrations, indexes, and DB config.

---

## 14. MVP Scope

Start with:

* one workload
* one database engine
* one framework adapter
* one app-under-test repo
* runner-side latency measurement
* DB control-plane query stats
* adapter-based schema/load/reset lifecycle
* initial optimization loop limited to indexes and simple app/query changes

A good first version is:

* Postgres
* Rails app
* Rails adapter
* simplified TPC-C-like or YCSB-like workload

---

## 15. Future Extensions

* support more framework adapters
* support more workload families
* request-to-query correlation via wrapper instrumentation
* distributed runners
* plan-diff analysis
* snapshot-based fast resets
* multiple experimental visibility modes for LLMs
* automatic workload synthesis

---

## 16. Summary

This system is a language-agnostic performance sandbox for evaluating and improving database-backed web applications using LLMs.

The defining design choices are:

* keep the application repo as normal as possible
* move benchmark lifecycle logic into separate adapters
* use the database engine control plane as the primary observability layer
* drive normal application endpoints rather than benchmark-only routes
* preserve deterministic experiment setup for repeated optimization loops

That gives you a much cleaner and more realistic platform than embedding benchmark APIs directly into every app.

---

My blunt take: this revised design is better than the earlier one. The earlier version was convenient for implementation, but it leaked too much harness logic into the target app. For what you actually want to measure, external adapters plus DB-layer observability is the right call.

The next useful step is to pin down one concrete adapter contract and one concrete repo layout, because that’s where hand-wavy architecture usually falls apart.

Good. This is the point where the design either becomes buildable or stays vibes.

You want an adapter contract that is:

* narrow
* framework-neutral
* easy to invoke from the runner
* not leaky into the app repo
* still strong enough to support deterministic setup, load, reset, and execution

I’d design this in two layers:

1. a **logical adapter interface**
2. a **practical transport shape** for invoking it

Then I’d choose a repo layout that keeps the boundaries obvious.

---

# 1. What the adapter is actually responsible for

The adapter exists to bridge between:

* the **generic benchmark runner**
* and a **specific app/framework repo**

It should not own:

* workload semantics
* traffic generation
* query observability
* LLM logic

It should own:

* environment prep
* schema/migration lifecycle
* dataset load
* app boot/stop
* state reset
* health checks
* framework-specific metadata discovery

So the core responsibility is:

> **make an app-under-test look runnable and resettable to the harness**

That’s it.

---

# 2. Adapter contract: logical interface

I’d define the adapter around **run lifecycle** and **dataset lifecycle**.

## Core methods

### Environment lifecycle

* `prepare`
* `start`
* `stop`
* `health`
* `base_url`

### Schema/data lifecycle

* `migrate`
* `load_dataset`
* `reset_state`

### Metadata / capabilities

* `capabilities`
* `describe`

That gives you something like:

```text
prepare() -> Result
start() -> Result
stop() -> Result
health() -> HealthStatus
base_url() -> URL

migrate(schema_version?: string) -> Result
load_dataset(workload:, scale:, seed:, options:) -> Result
reset_state(mode:, seed?: int) -> Result

capabilities() -> AdapterCapabilities
describe() -> AdapterDescription
```

---

# 3. What each method should mean

## `prepare`

Sets up everything required before a run, except actually starting the app.

May include:

* dependency install
* config file generation
* env var setup
* container network/bootstrap
* DB creation if needed

Should be **safe to call multiple times**.

---

## `start`

Starts the app and blocks until it is ready or times out.

Should:

* boot the app in a benchmarkable environment
* return enough metadata for the runner to proceed
* avoid hidden one-time migration/setup work if possible

Output should include:

* pid / process handle reference if local
* base URL
* startup logs path or summary

---

## `stop`

Stops the app cleanly.

Should:

* terminate process/container
* flush logs if relevant
* return quickly and deterministically

---

## `health`

Checks whether the started app is ready to receive traffic.

Should return structured status, not just exit codes.

Example:

```json
{
  "ok": true,
  "base_url": "http://127.0.0.1:3000",
  "checks": {
    "http": "ok",
    "db_connectivity": "ok"
  }
}
```

---

## `base_url`

Returns the externally reachable base URL for workload traffic.

You could fold this into `health`, but it is convenient to expose directly too.

---

## `migrate`

Applies schema setup using framework-native mechanisms.

Examples:

* Rails: migrations
* Express: knex/prisma/sequelize migration command
* Java: Flyway/Liquibase / startup task

This is important: it should not require benchmark-only app routes.

---

## `load_dataset`

Loads a deterministic dataset for a named workload.

Inputs should include:

* workload name
* scale factor
* seed
* optional variant/options

Example:

```json
{
  "workload": "tpcc-web",
  "scale": 10,
  "seed": 42,
  "options": {
    "warehouses": 10
  }
}
```

The adapter can implement this by:

* invoking a framework-native seed command
* calling a benchmark seed library
* launching a one-shot bootstrap process

This is probably the most framework-specific part of the contract.

---

## `reset_state`

Returns the system to a known baseline between runs.

You need explicit reset modes.

I’d define at least:

* `soft`: clear transient state, preserve schema and loaded dataset if possible
* `dataset`: rebuild loaded data for same schema
* `full`: recreate DB, rerun schema, reload data

Example request:

```json
{
  "mode": "full",
  "seed": 42
}
```

This matters because fast iteration for LLM loops may want `soft` or `dataset`, while correctness checks may require `full`.

---

## `capabilities`

Returns what the adapter supports.

Example:

```json
{
  "framework": "rails",
  "language": "ruby",
  "supports": {
    "prepare": true,
    "migrate": true,
    "load_dataset": true,
    "reset_modes": ["soft", "dataset", "full"],
    "start_stop": true,
    "per_run_env_overrides": true
  }
}
```

This lets the runner degrade gracefully instead of guessing.

---

## `describe`

Returns descriptive metadata.

Example:

```json
{
  "name": "rails-postgres-adapter",
  "framework": "rails",
  "runtime": "ruby-3.3",
  "app_type": "web",
  "default_port": 3000,
  "notes": [
    "Uses bin/rails db:migrate",
    "Uses runner-based dataset load"
  ]
}
```

This is useful for experiment records.

---

# 4. Transport shape: how the runner should call adapters

You have three choices:

## Option A: CLI contract

Simplest and best starting point.

Example:

```bash
bench-adapter prepare
bench-adapter migrate
bench-adapter load-dataset --workload tpcc-web --scale 10 --seed 42
bench-adapter reset-state --mode full --seed 42
bench-adapter start
bench-adapter health
bench-adapter base-url
bench-adapter stop
bench-adapter capabilities
bench-adapter describe
```

### Why I like it

* easy to build
* easy to debug
* works in CI
* avoids long-running adapter daemons at first
* maps well to containers too

### Downside

You have to handle state between commands somehow.

That can be solved by a state directory.

---

## Option B: local RPC / HTTP adapter service

Example: runner talks to `localhost:7788`.

### Why you might want it later

* cleaner structured state
* easier streaming logs/events
* richer long-running operations

### Why not first

* more moving parts
* another process to manage
* not necessary until you need remote adapters or richer orchestration

---

## Option C: library interface

Runner imports adapter classes directly.

### Why I would avoid it

* couples runner language to adapter language
* awkward across Rails/Node/Java
* bad fit for your cross-language goal

So: **start with CLI**.

---

# 5. CLI contract: concrete shape

I’d make every command support:

* `--state-dir`
* `--app-root`
* `--config`
* `--json`

This keeps the interface machine-friendly.

## Example commands

```bash
bench-adapter prepare \
  --app-root /apps/rails-tpcc \
  --state-dir /tmp/bench-run-123 \
  --config /configs/run.json \
  --json
```

```bash
bench-adapter load-dataset \
  --app-root /apps/rails-tpcc \
  --state-dir /tmp/bench-run-123 \
  --workload tpcc-web \
  --scale 10 \
  --seed 42 \
  --json
```

```bash
bench-adapter start \
  --app-root /apps/rails-tpcc \
  --state-dir /tmp/bench-run-123 \
  --json
```

## Example JSON response

```json
{
  "ok": true,
  "command": "start",
  "base_url": "http://127.0.0.1:3000",
  "state": {
    "pid": 48291,
    "port": 3000
  }
}
```

---

# 6. State model

You need the adapter to remember things between invocations.

Use a per-run **state directory** controlled by the runner.

Example contents:

```text
/tmp/bench-run-123/
  adapter-state.json
  app.pid
  app.stdout.log
  app.stderr.log
  env.json
  ports.json
```

This is much cleaner than forcing commands to rediscover everything each time.

The runner owns the lifecycle of `state-dir`. The adapter reads/writes inside it.

---

# 7. Repo layout options

There are two sane topologies.

## Option 1: polyrepo

Separate repos for:

* app-under-test
* adapter(s)
* runner/orchestrator
* workload specs

### Example

```text
bench-runner/
bench-workloads/
bench-adapter-rails/
bench-adapter-express/
bench-adapter-dropwizard/
apps/
  rails-tpcc-app/
  express-tpcc-app/
  dropwizard-tpcc-app/
```

### Pros

* very clean boundaries
* app repos stay realistic
* best for “blind LLM sees only app repo”

### Cons

* more repo management
* a little more operational glue

If your experiments care about visibility isolation, this is strong.

---

## Option 2: monorepo with hard boundaries

Everything in one repo, but separated by directories and access controls.

### Example

```text
/runner
/workloads
/adapters/rails
/adapters/express
/adapters/dropwizard
/apps/rails-tpcc
/apps/express-tpcc
/apps/dropwizard-tpcc
/infra
/docs
```

### Pros

* easier local dev
* easier CI
* easier synchronized changes

### Cons

* easier for the LLM to see harness code unless you deliberately restrict its context
* weaker conceptual isolation

This is easier to build first, but you’ll need discipline in experiments.

---

# 8. My actual recommendation on repo layout

Use a **hybrid**:

* start with a **monorepo for development speed**
* but structure it as if it were polyrepo
* ensure the LLM tooling can be pointed at only `/apps/<target-app>` when needed

So something like:

```text
/bench-platform
  /runner
  /workloads
    /tpcc-web
    /ycsb-web
  /adapters
    /rails
    /express
    /dropwizard
  /apps
    /rails-tpcc
    /express-tpcc
    /dropwizard-tpcc
  /infra
    /docker
    /compose
    /scripts
  /docs
```

This gives you speed now and separation later.

If an app graduates into a more “realistic” standalone evaluation target, split it into its own repo later.

---

# 9. Recommended directory structure in more detail

## `/runner`

Owns:

* HTTP worker engine
* workload execution
* experiment sequencing
* result collection
* adapter invocation
* LLM optimization orchestration

Example:

```text
/runner
  /lib
    /bench_runner
      adapter_client.rb
      experiment.rb
      worker.rb
      scheduler.rb
      result.rb
      report.rb
  /bin
    bench-runner
```

---

## `/workloads`

Owns:

* declarative workload specs
* payload models
* validation rules
* scenario templates

Example:

```text
/workloads
  /tpcc-web
    workload.json
    payload_models.json
    phases.json
  /ycsb-web
    workload.json
```

---

## `/adapters/<framework>`

Owns:

* framework-specific CLI adapter implementation
* bootstrap helpers
* benchmark seed integration
* runtime conventions

Example:

```text
/adapters/rails
  /bin
    bench-adapter
  /lib
    adapter.rb
    commands/
      prepare.rb
      migrate.rb
      load_dataset.rb
      reset_state.rb
      start.rb
      stop.rb
      health.rb
```

---

## `/apps/<target>`

Owns:

* the actual application under test
* business code
* migrations
* normal routes
* normal configs

Example:

```text
/apps/rails-tpcc
  app/
  config/
  db/
  Gemfile
  bin/
```

Ideally no benchmark routes.

---

## `/infra`

Owns:

* docker compose
* local DB boot
* snapshot scripts
* helper scripts
* CI env setup

Example:

```text
/infra
  /docker
  /compose
  /scripts
```

---

# 10. Adapter command design: more specific

Here’s a concrete CLI shape I’d actually endorse.

## Required commands

### `describe`

Static metadata.

```bash
bench-adapter describe --json
```

### `capabilities`

Feature support.

```bash
bench-adapter capabilities --json
```

### `prepare`

Install/setup environment.

```bash
bench-adapter prepare --app-root ... --state-dir ... --json
```

### `migrate`

Apply schema.

```bash
bench-adapter migrate --app-root ... --state-dir ... --json
```

### `load-dataset`

Load named workload dataset.

```bash
bench-adapter load-dataset \
  --app-root ... \
  --state-dir ... \
  --workload tpcc-web \
  --scale 10 \
  --seed 42 \
  --json
```

### `reset-state`

Reset to known baseline.

```bash
bench-adapter reset-state \
  --app-root ... \
  --state-dir ... \
  --mode full \
  --seed 42 \
  --json
```

### `start`

Start app.

```bash
bench-adapter start --app-root ... --state-dir ... --json
```

### `health`

Check readiness.

```bash
bench-adapter health --app-root ... --state-dir ... --json
```

### `base-url`

Return traffic target.

```bash
bench-adapter base-url --app-root ... --state-dir ... --json
```

### `stop`

Stop app.

```bash
bench-adapter stop --app-root ... --state-dir ... --json
```

---

# 11. A few optional commands worth adding early

These are optional, but useful.

## `logs`

Return or tail logs path(s).

```bash
bench-adapter logs --state-dir ...
```

## `env`

Return runtime environment snapshot.

```bash
bench-adapter env --state-dir ... --json
```

## `seed-info`

Describe what dataset was loaded.

```bash
bench-adapter seed-info --state-dir ... --json
```

That helps experiment traceability a lot.

---

# 12. What `load_dataset` should not do

This matters.

It should not:

* implicitly start the app unless explicitly documented
* silently migrate schema unless that’s unavoidable
* mutate workload definitions
* depend on benchmark HTTP routes

Keep side effects obvious.

---

# 13. Rails mapping example

A Rails adapter can map contract methods like this:

## `prepare`

* bundle install if needed
* generate runtime env file
* ensure DB exists

## `migrate`

* `bin/rails db:migrate`

## `load-dataset`

* `bin/rails runner 'BenchmarkSeed.load(...)'`

## `reset-state`

* `bin/rails db:drop db:create db:migrate`
* rerun load if mode is `full`

## `start`

* `bin/rails server -p <allocated_port>`

## `health`

* poll `/up` or configured health route

This is exactly the kind of framework-native behavior you want.

---

# 14. Express mapping example

## `prepare`

* install deps
* generate env config

## `migrate`

* run knex/prisma/sequelize migration CLI

## `load-dataset`

* run seed script or Node bootstrap module

## `start`

* `node server.js` or framework-specific boot command

## `health`

* poll standard health endpoint

Again: no `__bench` routes required.

---

# 15. Interaction between runner and adapter

The runner’s adapter client should be dumb and strict.

Pseudo-Ruby:

```ruby
class AdapterClient
  def initialize(bin:, app_root:, state_dir:)
    @bin = bin
    @app_root = app_root
    @state_dir = state_dir
  end

  def run(command, **kwargs)
    args = build_args(command, kwargs)
    stdout = Open3.capture3(*args)
    parse_json(stdout)
  end

  def prepare = run("prepare")
  def migrate = run("migrate")
  def load_dataset(workload:, scale:, seed:, options: nil)
    run("load-dataset", workload:, scale:, seed:, options: options && JSON.dump(options))
  end
  def reset_state(mode:, seed: nil)
    run("reset-state", mode:, seed:)
  end
  def start = run("start")
  def stop = run("stop")
  def health = run("health")
  def base_url = run("base-url")
end
```

The runner should not know anything about Rails vs Node vs Java beyond the adapter binary path.

---

# 16. Versioning the contract

Do this early or you’ll regret it.

Add:

* `adapter_api_version`
* `workload_spec_version`

For example:

```json
{
  "adapter_api_version": "1.0",
  "name": "rails-postgres-adapter",
  "framework": "rails"
}
```

That lets you evolve commands safely.

---

# 17. Design constraints I’d explicitly document

These should be hard rules.

## Rule 1

The adapter must be usable without modifying the runner for each framework.

## Rule 2

The app-under-test should not be required to expose benchmark-only HTTP routes.

## Rule 3

The adapter should use ordinary framework-native setup and execution mechanisms.

## Rule 4

The adapter must produce structured machine-readable responses.

## Rule 5

Per-run state must live in a runner-provided state directory.

## Rule 6

Reset semantics must be explicit and documented.

---

# 18. My blunt recommendation

Don’t overdesign this into a distributed control plane yet.

Start with:

* monorepo
* CLI adapters
* state-dir-based command protocol
* one Rails adapter
* one app
* one workload

That is enough to validate:

* separation of concerns
* reproducibility
* usefulness for the LLM loop

If you can’t make the CLI contract feel clean in Rails, the architecture is still too vague.

---

# 19. Updated design doc section you can drop in

## Adapter Contract

The benchmark harness interacts with framework-specific adapters through a narrow external contract. Adapters are responsible for preparing, migrating, seeding, resetting, starting, stopping, and health-checking applications under test using framework-native mechanisms. Adapters are not responsible for workload execution, observability, or optimization logic.

The initial transport for this contract is a CLI interface. Each adapter must implement the following commands:

* `describe`
* `capabilities`
* `prepare`
* `migrate`
* `load-dataset`
* `reset-state`
* `start`
* `health`
* `base-url`
* `stop`

Each command must accept a runner-provided `state-dir` argument and should emit structured JSON responses. The `state-dir` is used to persist per-run process metadata, logs, port allocations, and environment information across invocations.

The adapter must operate without requiring the application under test to expose benchmark-only HTTP endpoints. Instead, it should invoke normal framework-native lifecycle mechanisms such as migrations, seed scripts, runner tasks, startup commands, and health endpoints.

### Reset modes

Adapters must document supported reset modes. The minimum expected modes are:

* `soft`: clear transient runtime state while preserving schema and dataset when possible
* `dataset`: rebuild or reload the dataset for the current schema
* `full`: recreate schema and reload data from scratch

### Versioning

Adapters must expose an `adapter_api_version` field in `describe` and `capabilities` responses. Workload specifications must also be versioned independently.

## Recommended Repository Layout

A single development monorepo is recommended initially, with boundaries structured to preserve future polyrepo separation:

```text
/bench-platform
  /runner
  /workloads
  /adapters
    /rails
    /express
    /dropwizard
  /apps
    /rails-tpcc
    /express-tpcc
    /dropwizard-tpcc
  /infra
  /docs
```

* `/runner` contains the generic load runner, experiment orchestrator, adapter client, and reporting logic.
* `/workloads` contains declarative workload specifications, payload models, and phase definitions.
* `/adapters/<framework>` contains framework-specific adapter implementations and bootstrap helpers.
* `/apps/<target>` contains the application under test and should remain as close as possible to a normal application repository.
* `/infra` contains environment setup, container orchestration, snapshot helpers, and CI-related scripts.

This layout allows the system to be developed conveniently as one codebase while preserving the conceptual isolation needed for experiments where the LLM should only inspect the application under test.


