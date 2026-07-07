# DevOps Teaching Repository Standards

---

# 1. Purpose

This repository teaches DevOps concepts in a structured, progressive, and production-oriented manner.

All content must:

- Be technically accurate
- Follow real-world best practices
- Be beginner-readable but production-aware
- Avoid toy examples unless clearly marked
- Teach WHY, not just HOW
- Build systems thinking

This is not a snippet dump repository.
This is a structured engineering curriculum.

---

# 2. Repository Architecture

## 2.1 Top-Level Structure (Domains)

Top-level directories represent infrastructure domains.

Examples:

- kubernetes/
- terraform/
- docker/
- networking/
- cicd/
- observability/
- security/

No concept files are allowed directly at repository root.

Each domain MUST contain:

- README.md (domain-level overview)
- Subdirectories representing abstract concepts

---

## 2.2 Domain-Level README Requirements

Each domain directory MUST contain a README.md with the following structure:

# Domain Name

## What This Domain Is
High-level explanation of the technology domain.

## Why This Domain Exists
Core engineering problems this domain was created to solve.

## Historical Background
How things worked before this technology emerged.
Limitations and pain points.
Industry evolution that led to its creation.

## Important Technical Problems It Solves
Concrete technical challenges:
- Scalability
- State management
- Deployment automation
- Resource isolation
- Reliability
- Observability
- etc.

## General Facts
Key architectural characteristics:
- Declarative vs imperative
- Stateless vs stateful
- Control plane vs data plane
- Immutable vs mutable infrastructure
- etc.

## Dependencies (Prerequisites)
Explicit list of required prior knowledge.

Example:
- Linux fundamentals
- Networking basics
- Containers (for Kubernetes)
- Git (for GitOps)

This section must be explicit and structured.

## Where It Fits in Modern Architecture
Explain integration with other domains.
Show real-world system interaction.

## Concept Map
Logical learning order of sub-concepts within the domain.

Example (Kubernetes):
1. Pods
2. Deployments
3. Services
4. Ingress
5. StatefulSets
6. Scheduling
7. GitOps

## Industry Adoption
Brief overview of real-world adoption and relevance.

## Common Misconceptions
Clarify misunderstandings about the domain.

Domain-level README files must:
- Be architectural
- Avoid jumping directly into YAML/code
- Prepare mental models before implementation

---

## 2.3 Concept-Level Structure

Each domain contains subdirectories representing abstract concepts.

Example:

kubernetes/
  pods/
  deployments/
  services/

Each concept directory MUST contain:

concept-name/
  README.md
  examples/
  exercises/

No mixing of concepts.
No flat dumping of files.

---

# 3. Concept README Requirements

Each concept README must include:

# Concept Name

## What This Concept Is
Precise technical definition.

## Why It Exists
Problem it solves within the domain.

## How It Works Internally
Lifecycle, mechanics, internal behavior.

## Production Relevance
How it is used in real-world systems.

## Architecture Diagram
ASCII or markdown diagram when applicable.

## Real-World Use Case
Concrete scenario from production systems.

## Common Mistakes
Typical beginner errors.

## Anti-Patterns
Production mistakes and poor practices.

## How It Connects to Other Concepts
Systems-thinking explanation.

## Examples
Reference ./examples

## Exercises
Reference ./exercises

Concept README must be comprehensive and educational.

---

# 4. Examples Directory Standards

## Naming

Examples must be progressively numbered:

examples/
  01-basic.yaml
  02-intermediate.yaml
  03-production-pattern.yaml

Numbers represent learning progression.

## Quality Requirements

Examples must:

- Use explicit versions (no "latest")
- Include resource limits (for Kubernetes)
- Avoid hardcoded secrets
- Follow infrastructure best practices
- Be syntactically valid
- Include comments explaining WHY decisions are made

Examples must NOT:

- Promote anti-patterns without labeling them
- Use insecure defaults without explanation
- Skip required metadata

---

# 5. Exercises Directory Standards

Exercises must be markdown files.

Each exercise must include:

## Objective
## Constraints
## Requirements
## Success Criteria
## Bonus Challenge (Optional)
## Reflection Question

Exercises must encourage:

- Critical thinking
- Debugging skills
- Production reasoning
- Systems thinking

No solution files in main branch unless explicitly required.

---

# 6. Code Standards

## 6.1 Kubernetes

All Kubernetes examples must:

- Avoid default namespace
- Include resource requests and limits
- Avoid "latest" image tags
- Include labels
- Use supported API versions
- Avoid deprecated fields
- Follow recommended production patterns

---

## 6.2 Terraform

All Terraform examples must:

- Use typed variables
- Avoid hardcoded values
- Include outputs
- Avoid inline provider credentials
- Follow module structure best practices
- Demonstrate remote state for production examples

---

## 6.3 Docker

Docker examples must:

- Pin base image versions
- Avoid running as root (for production examples)
- Use multi-stage builds when relevant
- Explain layer caching

---

## 6.4 CI/CD

CI examples must:

- Separate build and deploy stages
- Avoid secret exposure
- Use least privilege permissions
- Demonstrate artifact usage
- Follow secure pipeline practices

---

# 7. Security Standards

The repository must:

- Never contain real credentials
- Never encourage secret hardcoding
- Teach least privilege
- Demonstrate secure defaults
- Clearly label insecure anti-pattern examples

Security is a first-class concern.

---

# 8. Teaching Philosophy

This repository teaches:

- Systems thinking
- Abstraction layers
- Infrastructure reasoning
- Debugging mindset
- Production engineering discipline

It does NOT teach:

- Blind copy-paste DevOps
- Tool memorization without context
- Shortcut-based practices

Each concept must answer:

- Why does this exist?
- What breaks if misused?
- What does this look like in production?

---

# 9. Progression Model

Concepts must build logically.

Example (Kubernetes progression):

1. Pods
2. Deployments
3. Services
4. Ingress
5. StatefulSets
6. Resource Management
7. Scheduling
8. GitOps

No advanced topics before foundations.

---

# 10. Documentation Rules

- Every domain must have a domain-level README.
- Every concept must have a README.
- Cross-link related concepts.
- Use relative links.
- Avoid dead links.
- Maintain consistent structure across domains.

---

# 11. CI & Validation Expectations

All example code should be:

- Lintable
- Formatted
- Valid syntax
- Compatible with current stable versions

Future CI should include:

- Markdown lint
- YAML lint
- Terraform validation
- Helm lint (if applicable)
- Shellcheck (if applicable)

---

# 12. Claude Generation Rules

When generating content for this repository:

- Follow this standards file strictly.
- Maintain directory hierarchy rules.
- Maintain naming conventions.
- Maintain production-awareness.
- Generate complete structured README files.
- Never generate flat content outside the defined hierarchy.
- Default to stricter engineering practices when uncertain.

Claude must behave as a senior DevOps architect designing curriculum.

---

# 13. Non-Negotiable Rules

- No dumping random files.
- No mixing unrelated concepts in one folder.
- No hardcoded secrets.
- No incomplete explanations.
- No skipping historical context.
- No skipping "Why".

---

# Guiding Principle

This repository must reflect how a senior DevOps engineer thinks,
not how a beginner copies commands.
