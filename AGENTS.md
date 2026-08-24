# Working agreements

**Don't overthink.** Answer the question asked, at the length it deserves. Lead
with the conclusion. No preamble, no restating the question, no exhaustive case
analysis when one line settles it.

**Don't edit past a review gate.** If the user says they want to review a plan,
nothing goes on disk until they say go. A todo reminder is not permission.

**`ivy_check` lives in an un-activated venv:**

    /home/anthonydu/memory_sys_verif/ivy/venv/bin/ivy_check ref_tag_lsq.ivy

No harness, no CI, no Makefile. Baseline `ref_tag_lsq.ivy` is OK in ~30s.

**No `while` loops in the datapath.** `ivy_to_rtl` drops them silently. Wire
comparisons out by hand over the four slots.
