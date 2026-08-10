# Shipeasy Ops Work Workflow

This project follows the `shipeasy-ops-work` workflow for all maintenance and feature tasks. Agents working on this repository MUST follow this exact process.

## The Workflow

1. **Discovery**: Fetch the list of open items from the Shipeasy Operational Queue.
   ```ruby
   admin.ops.list_ops_items(status: "open")
   ```
2. **Atomic Work**: Pick exactly **one** item to work on. Do not start multiple items.
3. **Claiming**: Mark the selected item as `in_progress` before starting any code changes.
   ```ruby
   admin.ops.update_ops_item(number, status: "in_progress")
   ```
4. **Implementation**:
   - Follow the guidance in `CLAUDE.md`.
   - If the public API changes, you **must** update `docs/` and regenerate `README.md` (`ruby scripts/gen_readme.rb`).
   - Run `rspec` to verify the changes.
5. **Submission**: Submit exactly **one PR per item**. Do not bundle multiple queue items into a single submission.
6. **Resolution**: After submission, mark the item as `resolved` in the queue.
   ```ruby
   admin.ops.update_ops_item(number, status: "resolved")
   ```

## Admin API Setup

To interact with the ops queue, use the `Shipeasy::Admin::Client`:

```ruby
require "shipeasy/admin"

admin = Shipeasy::Admin::Client.new(
  api_key: ENV.fetch("SHIPEASY_CLI_TOKEN"),
  project_id: ENV.fetch("SHIPEASY_PROJECT_ID")
)
```
