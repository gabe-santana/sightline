# Sightline documentation

Start with [../README.md](../README.md) for the project overview. This folder holds the detailed design:

1. [architecture.md](architecture.md) — VPC layout, services, and why the system is split the way it is
2. [data-flow.md](data-flow.md) — exact sequence of events for ingestion and for query
3. [agent-orchestration.md](agent-orchestration.md) — how the autonomous query agent plans, calls tools, and stays grounded
4. [schemas.md](schemas.md) — the JSON Schemas that make agent output auditable
5. [cost-and-reliability.md](cost-and-reliability.md) — the cost model and the failure-handling design
6. [evaluation-strategy.md](evaluation-strategy.md) — how accuracy is measured and proven, not asserted
7. [local-development.md](local-development.md) — running the whole pipeline locally against `docker-compose.yml`, and what's a faithful AWS emulation vs. a mock
8. [proposal-apex-financial.md](proposal-apex-financial.md) — the formal proposal this design was built to answer
9. [Infra.drawio](Infra.drawio) — source diagram (open in [draw.io](https://app.diagrams.net/) or the VS Code draw.io extension)

Read order for a new team member: architecture → data-flow → agent-orchestration → schemas. Read order for evaluating the proposal against the RFP: proposal-apex-financial → the rest as referenced from it.
