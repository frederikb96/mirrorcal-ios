#!/usr/bin/env python3
"""Catch the Swift 6 / SwiftUI mistakes that compile nowhere but a metered macOS runner.

``parse-swift.sh`` stops before name resolution, so everything below is invisible to it — and the
package build never sees the app target at all. Every pattern here is one that has actually failed
a Mac run, and a Mac run costs ten times a Linux minute to answer what a scan answers for nothing.

Heuristics, not a compiler. They are deliberately narrow, and each errs towards missing a real
problem rather than flagging a good line: the Mac run is still the real check, so a miss costs one
run while a false positive blocks work every time it fires.

Add a check when a Mac run fails for a reason a scan could have found.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

TYPE_DECLARATION = re.compile(r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:public |internal |private |fileprivate |final |open )*(?:class|struct|enum|actor|extension)\b")
STORED_STATIC_VAR = re.compile(r"^\s*(?:public |internal |private |fileprivate )?static var [A-Za-z_]\w*\s*(?::[^={]*)?=")
SHADOWED_WRAPPER = re.compile(r"^\s*(?:public |internal |private |fileprivate )?(?:enum|struct|class|actor) (State|Binding|Environment|Namespace|Observable)\s*[:{]")
AMBIGUOUS_PAIR = re.compile(r"(?:width|x|dx): \.[A-Za-z]\w*, (?:height|y|dy): \.[A-Za-z]\w*")
ISOLATED_STATIC = re.compile(r"^\s*(?:public |internal |private |fileprivate )?static (?:let|var) ([A-Za-z_]\w*)\b")
DETACHED_TASK = re.compile(r"\bTask\.detached\b")
#: A one-line `guard ... else { return ... }` — the shape that disqualifies a following `switch`
#: from the compiler's implicit-return-expression inference, since that only applies when the
#: `switch`/`if` is the *sole* statement of the enclosing body.
GUARD_ELSE_RETURN = re.compile(r"^\s*guard\b.*\belse\s*\{\s*return\b")
SWITCH_STATEMENT = re.compile(r"^\s*switch\b")
#: A `case`/`default` whose body sits on the same line — the only shape this check can read
#: without a parser, and also the shape every real instance of this bug has taken.
CASE_SAME_LINE_BODY = re.compile(r"^\s*(?:case\b[^:]*|default)\s*:\s*(\S.*)$")
#: `nonisolated(unsafe)` is a property qualifier, not a function opting out of actor isolation —
#: the negative lookahead is what keeps it out of this match.
NONISOLATED_FUNC = re.compile(r"\bnonisolated(?!\()\b.*\bfunc\b")

#: Main-thread-only UIKit surface, as textual fragments rather than full type signatures — narrow
#: on purpose, matching `IMPLICITLY_ISOLATED_BASE`'s own shape, so a hit is a real access rather
#: than a coincidental substring.
UIKIT_MAIN_THREAD_ONLY = re.compile(
    r"UIApplication\.shared"
    r"|UIPasteboard\.general"
    r"|\.becomeFirstResponder\("
    r"|\.resignFirstResponder\("
    r"|\.present\("
    r"|\.dismiss\("
    r"|\bUICollectionView\b"
    r"|\bUIScrollView\b"
    r"|\bUINotificationFeedbackGenerator\b"
)


#: Inheriting from one of these carries main-actor isolation with no annotation in sight — the
#: SDK declares them `@MainActor`. A `UIViewController` subclass's statics are isolated and legal,
#: and reporting them is the false positive that makes a check like this get ignored.
IMPLICITLY_ISOLATED_BASE = re.compile(r":\s*(?:[\w.]+\s*,\s*)*(?:UI[A-Z]\w*|NS[A-Z]\w*View\w*)\b")


def main_actor_line_numbers(lines: list[str]) -> set[int]:
    """Line numbers covered by a main-actor-isolated *type*.

    A static inside one is actor-isolated and legal. Isolation has to be attributed to the type
    rather than merely present in the file: `@MainActor` on a single method — which is how it
    usually appears in an `AppIntent` — isolates nothing about the type's statics, and treating the
    whole file as safe there is what let an earlier version of this check miss the very error it
    was written for.

    Scoping is by indentation rather than by brace matching, which is enough for the one question
    being asked and does not need a parser.
    """
    covered: set[int] = set()
    for index, line in enumerate(lines):
        isolated_here = "@MainActor" in line
        inherits = TYPE_DECLARATION.match(line) and IMPLICITLY_ISOLATED_BASE.search(line)
        if not isolated_here and not inherits:
            continue
        # The declaration is on this line, or on the next non-blank one.
        declaration = index if TYPE_DECLARATION.match(line) else None
        if declaration is None:
            for lookahead in range(index + 1, min(index + 4, len(lines))):
                if not lines[lookahead].strip():
                    continue
                if TYPE_DECLARATION.match(lines[lookahead]):
                    declaration = lookahead
                break
        if declaration is None:
            continue
        indent = len(lines[declaration]) - len(lines[declaration].lstrip())
        # A long inheritance list wraps, and the opening brace then sits on its own line at the
        # declaration's own indent — which the scope walk below would read as the end of the type
        # before it has seen any of it. Find the brace first and scope from there.
        opening = declaration
        while opening < len(lines) and "{" not in lines[opening]:
            opening += 1
            if opening - declaration > 8:
                opening = declaration
                break
        for cursor in range(opening + 1, len(lines)):
            body = lines[cursor]
            if body.strip() and (len(body) - len(body.lstrip())) <= indent:
                break
            covered.add(cursor)
    return covered


def detached_reads_of_isolated_statics(lines: list[str], isolated: set[int]) -> list[tuple[int, str, str]]:
    """A static declared inside a main-actor type, read from inside `Task.detached`.

    The static is isolated to that actor, so the detached body cannot touch it — and the error
    names the *use*, several lines from the declaration that caused it. Everything else in the
    body is usually a `Sendable` snapshot taken deliberately, which is what makes the one
    unsnapshotted name easy to miss when reading.

    Scoped by indentation like the rest of this file. Only names declared in this same file count,
    so a static reached through a type prefix is not considered — that form is qualified and reads
    as remote, which is exactly when nobody needs a reminder.
    """
    names = {
        match.group(1)
        for index, line in enumerate(lines)
        if index in isolated and (match := ISOLATED_STATIC.match(line)) and "nonisolated" not in line
    }
    if not names:
        return []

    findings: list[tuple[int, str, str]] = []
    for index, line in enumerate(lines):
        if not DETACHED_TASK.search(line):
            continue
        indent = len(line) - len(line.lstrip())
        for cursor in range(index + 1, len(lines)):
            body = lines[cursor]
            if body.strip() and (len(body) - len(body.lstrip())) <= indent:
                break
            for name in names:
                if re.search(rf"(?<![.\w]){re.escape(name)}\b", body):
                    findings.append((
                        cursor + 1, body.strip(),
                        f"'{name}' is a static on a main-actor-isolated type and cannot be read "
                        "from a detached task — move it to file scope, or snapshot it before the task",
                    ))
    return findings


def nonisolated_uikit_access(lines: list[str]) -> list[tuple[int, str, str]]:
    """UIKit touched directly inside a function that opted out of actor isolation.

    `nonisolated func` is legitimate — it is how a delegate callback satisfies a protocol
    requirement that is not itself `@MainActor` — but the body then runs off the main actor
    unless it explicitly hops back (`await MainActor.run { ... }`), and a UIKit call written
    directly in that body raises "Call must be made on main thread" only at runtime, never at
    compile time. That crash shape is exactly what sent an investigation through ~110 `Task {}`
    sites and every `nonisolated` declaration in the app looking for a call site nobody could
    confirm; this rule exists to catch the next one before it needs that hunt.

    Textual and single-file, scoped by indentation like the rest of this module: it catches a
    UIKit call written directly in the nonisolated function's own body, and misses one reached
    through a plain helper two calls deep — the same limit `detached_reads_of_isolated_statics`
    already accepts for its own narrower case.
    """
    findings: list[tuple[int, str, str]] = []
    for index, line in enumerate(lines):
        if not NONISOLATED_FUNC.search(line):
            continue
        indent = len(line) - len(line.lstrip())
        opening = index
        while opening < len(lines) and opening - index <= 10 and "{" not in lines[opening]:
            opening += 1
        if opening >= len(lines) or "{" not in lines[opening]:
            # No body found within the lookahead — a protocol requirement with no
            # implementation, most likely. Nothing to scope, so nothing to scan.
            continue
        for cursor in range(opening + 1, len(lines)):
            body = lines[cursor]
            if body.strip() and (len(body) - len(body.lstrip())) <= indent:
                break
            match = UIKIT_MAIN_THREAD_ONLY.search(body)
            if match:
                findings.append((
                    cursor + 1, body.strip(),
                    f"'{match.group(0)}' is main-thread-only UIKit, called directly inside a "
                    "'nonisolated' function — hop to the main actor first "
                    "(await MainActor.run { ... })",
                ))
    return findings


def switch_after_guard_missing_return(lines: list[str]) -> list[tuple[int, str, str]]:
    """A `switch` right after a one-line `guard ... else { return ... }`, with a case whose
    same-line body has no `return`.

    `if`/`switch` as an expression only omits `return` when it is the *whole* body of the
    function/property/closure it sits in — a preceding `guard` makes it the second statement, and
    every case then needs an explicit `return` again. The error ("missing return in getter
    expected to return '...'") is a plain type error, so neither `parse-swift.sh` (stops before
    type checking) nor the package build (this shape lives only in the app target) can see it —
    a Mac run is the first thing that does.

    Narrow on purpose: it only reads a case whose body sits on the same line as the `case`, which
    is the shape every real instance of this bug has taken here. A case whose body is indented
    on the following line is not read at all, rather than risk misreading its indentation as a
    return.
    """
    findings: list[tuple[int, str, str]] = []
    for index, line in enumerate(lines):
        if not GUARD_ELSE_RETURN.match(line):
            continue
        indent = len(line) - len(line.lstrip())
        cursor = index + 1
        while cursor < len(lines) and not lines[cursor].strip():
            cursor += 1
        if cursor >= len(lines):
            continue
        candidate = lines[cursor]
        if (len(candidate) - len(candidate.lstrip())) != indent or not SWITCH_STATEMENT.match(candidate):
            continue
        for body_index in range(cursor + 1, len(lines)):
            body = lines[body_index]
            if not body.strip():
                continue
            # Strictly less than, not `<=`: a `case` label conventionally sits at the same
            # indent as its `switch`, which in turn sits at the same indent as the `guard`
            # above it — so `<=` would exit before ever reading a case.
            if (len(body) - len(body.lstrip())) < indent:
                break
            match = CASE_SAME_LINE_BODY.match(body)
            if match and not re.search(r"\b(?:return|break|continue|throw|fatalError)\b", match.group(1)):
                findings.append((
                    body_index + 1, body.strip(),
                    "this switch follows a guard, so it is not the sole statement of its body — "
                    "add 'return' (implicit-return switch expressions only apply when the switch "
                    "is the whole body)",
                ))
    return findings


#: An `NSObjectProtocol?` stored property — the token `NotificationCenter.addObserver` hands
#: back, and the shape every real instance of this bug has taken here.
OBSERVER_TOKEN_PROPERTY = re.compile(r"\bvar\s+([A-Za-z_]\w*)\s*:\s*NSObjectProtocol\?")
DEINIT_OPEN = re.compile(r"^\s*deinit\s*\{")


#: Reference types from frameworks this app actually links that do not declare `Sendable` — not
#: an attempt at a complete list, only the ones a parameter or a capture has actually been in the
#: two Mac runs this check exists to save. Extend it the same way as everything else here: the
#: next Mac run that fails on this shape names the type to add.
NON_SENDABLE_APPLE_TYPE = (
    r"EKEvent|EKEventStore|EKCalendar|EKParticipant|EKRecurrenceRule|EKAlarm"
    r"|BGTask|BGAppRefreshTask|BGProcessingTask|NWConnection|NWListener|CLLocation|UserDefaults"
)
NON_SENDABLE_PARAM = re.compile(rf"\b(\w+)\s*:\s*(?:{NON_SENDABLE_APPLE_TYPE})\??(?:\s*[,)])")
FUNC_OPEN = re.compile(r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:public |internal |private |fileprivate |static )*func\s+\w+")
TASK_OPEN = re.compile(r"\bTask(?:\.detached)?\s*(?:\([^)]*\))?\s*\{")


def sending_capture_in_task(lines: list[str]) -> list[tuple[int, str, str]]:
    """A known non-`Sendable` Apple type, taken as a function parameter, read inside a `Task {}`
    (or `Task.detached {}`) in that same function's body.

    The parameter crosses into the task's own isolation domain, which is exactly what Swift 6
    rejects with "sending '<value>' risks causing data races" — a diagnostic at the point of
    *use* inside the closure, several lines from the parameter that actually causes it, which is
    what makes it easy to write and easy to miss reading back. Neither `parse-swift.sh` nor the
    package build sees this: it needs full type checking, and the framework types it fires on
    live only in the app target.

    Scoped by indentation like the rest of this module. A parameter list spanning several lines
    is read up to the function's opening brace; the closure body is read from `Task {` to the
    line indentation returns to the closure's own opening indent.
    """
    findings: list[tuple[int, str, str]] = []
    for index, line in enumerate(lines):
        if not FUNC_OPEN.match(line):
            continue
        opening = index
        while opening < len(lines) and opening - index <= 15 and "{" not in lines[opening]:
            opening += 1
        if opening >= len(lines) or "{" not in lines[opening]:
            continue
        signature = "\n".join(lines[index : opening + 1])
        risky_params = {m.group(1) for m in NON_SENDABLE_PARAM.finditer(signature)}
        if not risky_params:
            continue

        indent = len(lines[index]) - len(lines[index].lstrip())
        for cursor in range(opening + 1, len(lines)):
            body = lines[cursor]
            if body.strip() and (len(body) - len(body.lstrip())) <= indent:
                break
            if not TASK_OPEN.search(body):
                continue
            task_indent = len(body) - len(body.lstrip())
            for inner in range(cursor + 1, len(lines)):
                inner_body = lines[inner]
                if inner_body.strip() and (len(inner_body) - len(inner_body.lstrip())) <= task_indent:
                    break
                for name in risky_params:
                    if re.search(rf"(?<![.\w]){re.escape(name)}\b", inner_body):
                        findings.append((
                            inner + 1, inner_body.strip(),
                            f"'{name}' is a non-Sendable Apple type taken as a parameter, read "
                            "inside this Task — Swift 6 will reject it as \"sending risks causing "
                            "data races\"; extract only the Sendable fields you need before the "
                            "Task, or make the whole call nonisolated and await it directly",
                        ))
    return findings


#: A type's own declaration line, capturing what kind it is, its name, and (if present on this
#: line) its inheritance clause — reused both to index every locally-declared type and to find
#: which of them opt into `Codable`.
TYPE_DECL_NAMED = re.compile(
    r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:public |internal |private |fileprivate |final |open )*"
    r"(?:struct|class|enum)\s+(\w+)(?:<[^>]*>)?\s*(?::\s*([^{]+))?\{"
)
EXTENSION_CONFORMANCE = re.compile(r"^\s*extension\s+(\w+)\s*:\s*([^{]+)\{")
CODABLE_CONFORMANCE = re.compile(r"\b(?:Codable|Encodable|Decodable)\b")
#: A stored property's declaration line: name, then its explicit type up to `=` or end of line.
#: Deliberately excludes a line containing `{` — a computed property's accessor block, whether
#: opened on this line or (checked separately) the next, is not a stored property and is not
#: subject to `Codable` synthesis at all.
STORED_PROPERTY = re.compile(
    r"^\s*(?:public |internal |private |fileprivate )?(?:let|var)\s+(\w+)\s*:\s*([^{\n=]+?)\s*(?:=.*)?$"
)


def build_codable_type_index(all_lines: dict[Path, list[str]]) -> tuple[set[str], set[str]]:
    """Every locally-declared type name, and the subset of those that conform to `Codable` (or
    `Encodable`/`Decodable`) somewhere — on the declaration itself or in a same-conformance
    extension anywhere in the scanned tree.
    """
    declared: set[str] = set()
    codable: set[str] = set()
    for lines in all_lines.values():
        for line in lines:
            if match := TYPE_DECL_NAMED.match(line):
                name, inheritance = match.group(1), match.group(2)
                declared.add(name)
                if inheritance and CODABLE_CONFORMANCE.search(inheritance):
                    codable.add(name)
            elif match := EXTENSION_CONFORMANCE.match(line):
                name, inheritance = match.group(1), match.group(2)
                if CODABLE_CONFORMANCE.search(inheritance):
                    codable.add(name)
    return declared, codable


def codable_type_embeds_non_codable_property(
    lines: list[str], non_codable_types: set[str]
) -> list[tuple[int, str, str]]:
    """A type that conforms to `Codable` (or `Encodable`/`Decodable`) with a stored property whose
    type is another type declared in this tree that does *not* conform.

    Synthesized `Codable` needs every stored property to conform too, and the compiler reports it
    as two separate `Decodable`/`Encodable` conformance errors on the *outer* type — which reads
    as two problems on a type whose own declaration looks correct, rather than one problem on the
    property that actually causes it. This is exactly the shape a package type deliberately
    carrying no persistence-format opinion (so it stays free of a `Codable` conformance) takes
    once something forgets that and stores it directly in a DTO instead of going through the
    conversion type that exists for this reason.

    Only checks locally-declared types (the index this is called with), so a framework type like
    `Date` or `String` is never flagged — this only ever fires on a real, findable non-conformance
    inside the same tree being scanned.
    """
    findings: list[tuple[int, str, str]] = []
    for index, line in enumerate(lines):
        match = TYPE_DECL_NAMED.match(line)
        if not match or not match.group(2) or not CODABLE_CONFORMANCE.search(match.group(2)):
            continue
        indent = len(line) - len(line.lstrip())
        for cursor in range(index + 1, len(lines)):
            body = lines[cursor]
            if body.strip() and (len(body) - len(body.lstrip())) <= indent:
                break
            prop = STORED_PROPERTY.match(body)
            if not prop:
                continue
            # A computed property whose accessor block opens on the following line reads
            # identically to a stored one up to here — the next non-blank line starting with
            # '{' is what actually distinguishes them, and Codable synthesis ignores computed
            # properties entirely, so flagging one would be a pure false positive.
            lookahead = cursor + 1
            while lookahead < len(lines) and not lines[lookahead].strip():
                lookahead += 1
            if lookahead < len(lines) and lines[lookahead].strip().startswith("{"):
                continue
            prop_name, prop_type = prop.group(1), prop.group(2)
            for type_name in re.findall(r"\b([A-Z]\w*)\b", prop_type):
                if type_name in non_codable_types:
                    findings.append((
                        cursor + 1, body.strip(),
                        f"'{prop_name}' is '{type_name}', which does not conform to Codable — "
                        f"'{match.group(1)}' will fail to synthesize Decodable/Encodable, "
                        "reported as two separate conformance errors on the outer type",
                    ))
                    break
    return findings


#: A protocol declared here that refines `Sendable` — used the same way `build_codable_type_index`
#: indexes `Codable` conformance: this file has no type checker, so conformance can only be read
#: from what a declaration literally says.
PROTOCOL_DECL_NAMED = re.compile(r"^\s*(?:public |internal |private |fileprivate )?protocol\s+(\w+)\s*(?::\s*([^{]+))?\{")


def build_sendable_conforming_type_index(all_lines: dict[Path, list[str]]) -> set[str]:
    """Every locally-declared struct/class/actor inferred `Sendable` — either its own declaration
    names `Sendable` directly, or it conforms to a locally-declared protocol whose own declaration
    names `Sendable` (one level of indirection, matching this file's `InstallationIdentityStore:
    Sendable` shape; a protocol refining Sendable only through *another* local protocol is not
    followed further).

    `@unchecked Sendable` is deliberately excluded: that annotation is the author asserting the
    compiler should not check this type, so a stored non-Sendable property there is not the Swift
    6 error this index exists to predict — it is the documented way out of one.
    """
    protocols_refining_sendable: set[str] = set()
    for lines in all_lines.values():
        for line in lines:
            match = PROTOCOL_DECL_NAMED.match(line)
            if match and match.group(2) and re.search(r"\bSendable\b", match.group(2)):
                protocols_refining_sendable.add(match.group(1))

    sendable_types: set[str] = set()
    for lines in all_lines.values():
        for line in lines:
            if "@unchecked Sendable" in line:
                continue
            match = TYPE_DECL_NAMED.match(line)
            if not match or not match.group(2):
                continue
            inheritance = match.group(2)
            if re.search(r"\bSendable\b", inheritance) or any(
                re.search(rf"\b{re.escape(name)}\b", inheritance) for name in protocols_refining_sendable
            ):
                sendable_types.add(match.group(1))
    return sendable_types


def sendable_type_embeds_non_sendable_property(
    lines: list[str], sendable_types: set[str]
) -> list[tuple[int, str, str]]:
    """A type inferred `Sendable` (see `build_sendable_conforming_type_index`) with a stored
    property typed as a known non-Sendable Apple type.

    Swift 6 rejects this with "stored property ... has non-Sendable type ..." right at the
    property — a plain diagnostic, but neither `parse-swift.sh` (stops before type checking) nor
    the package build (the framework types this fires on live only in the app target) can see it.
    `@unchecked Sendable` is the documented way out and is excluded from the index this reads, not
    flagged here.
    """
    findings: list[tuple[int, str, str]] = []
    for index, line in enumerate(lines):
        match = TYPE_DECL_NAMED.match(line)
        if not match or match.group(1) not in sendable_types:
            continue
        indent = len(line) - len(line.lstrip())
        for cursor in range(index + 1, len(lines)):
            body = lines[cursor]
            if body.strip() and (len(body) - len(body.lstrip())) <= indent:
                break
            prop = STORED_PROPERTY.match(body)
            if not prop:
                continue
            prop_name, prop_type = prop.group(1), prop.group(2)
            if re.search(rf"\b(?:{NON_SENDABLE_APPLE_TYPE})\b", prop_type):
                findings.append((
                    cursor + 1, body.strip(),
                    f"'{prop_name}' is '{prop_type.strip()}', which is not Sendable — "
                    f"'{match.group(1)}' conforms to Sendable (directly or through a protocol), "
                    "so this needs '@unchecked Sendable' or a Sendable-safe replacement",
                ))
    return findings


def unmarked_observer_token_read_in_deinit(
    lines: list[str], isolated: set[int]
) -> list[tuple[int, str, str]]:
    """An `NSObjectProtocol?` observer token read inside `deinit` without `nonisolated(unsafe)`.

    `NSObjectProtocol` is not `Sendable`, so a `deinit` on a main-actor-isolated type — always
    nonisolated itself, even though the class around it is `@MainActor` — cannot read a stored
    property of that type at all: "cannot access property '...' with a non-Sendable type '(any
    NSObjectProtocol)?' from nonisolated deinit". Neither `parse-swift.sh` nor the package build
    can see this (Sendable checking is part of full type checking, and this shape lives only in
    the app target), so a Mac run is the first thing that does. `VoiceRecorderController`'s own
    observer tokens already carry the fix this checks for — `nonisolated(unsafe)`, safe here
    because the property is written once on the main actor during setup and read once at
    deallocation, when nothing else holds a reference.

    Gated on `main_actor_line_numbers`: a plain, non-isolated class (`MicrophoneCapture`, which
    is `@unchecked Sendable` and explicitly not `@MainActor`) has no isolation boundary for its
    own `deinit` to cross, so the same read there is not an error — flagging it anyway is exactly
    the false positive that makes a check like this stop being trusted.

    Single-file and textual: it does not follow a token into a helper `deinit` calls, only one
    read directly in the `deinit` body itself.
    """
    findings: list[tuple[int, str, str]] = []
    unmarked = {
        match.group(1) for line in lines
        if (match := OBSERVER_TOKEN_PROPERTY.search(line)) and "nonisolated(unsafe)" not in line
    }
    if not unmarked:
        return findings
    for index, line in enumerate(lines):
        if not DEINIT_OPEN.match(line) or index not in isolated:
            continue
        indent = len(line) - len(line.lstrip())
        for cursor in range(index + 1, len(lines)):
            body = lines[cursor]
            if body.strip() and (len(body) - len(body.lstrip())) <= indent:
                break
            for name in unmarked:
                if re.search(rf"\b{re.escape(name)}\b", body):
                    findings.append((
                        cursor + 1, body.strip(),
                        f"'{name}' is an unmarked 'NSObjectProtocol?' read from nonisolated "
                        "deinit — declare it 'private nonisolated(unsafe) var' instead",
                    ))
    return findings


def check(
    path: Path, lines: list[str], non_codable_types: set[str], sendable_types: set[str]
) -> list[tuple[int, str, str]]:
    isolated = main_actor_line_numbers(lines)
    findings: list[tuple[int, str, str]] = detached_reads_of_isolated_statics(lines, isolated)
    findings.extend(nonisolated_uikit_access(lines))
    findings.extend(switch_after_guard_missing_return(lines))
    findings.extend(unmarked_observer_token_read_in_deinit(lines, isolated))
    findings.extend(sending_capture_in_task(lines))
    findings.extend(codable_type_embeds_non_codable_property(lines, non_codable_types))
    findings.extend(sendable_type_embeds_non_sendable_property(lines, sendable_types))

    for index, line in enumerate(lines):
        if STORED_STATIC_VAR.match(line) and index not in isolated and "nonisolated(unsafe)" not in line:
            findings.append((
                index + 1, line.strip(),
                "stored 'static var' is global mutable state under Swift 6 — make it computed "
                "({ ... }), a 'static let', or 'nonisolated(unsafe)'",
            ))
        if SHADOWED_WRAPPER.match(line):
            findings.append((
                index + 1, line.strip(),
                "a type named after a SwiftUI property wrapper shadows it in this scope — rename it",
            ))
        if AMBIGUOUS_PAIR.search(line):
            findings.append((
                index + 1, line.strip(),
                "both members inferred leaves the literal's type ambiguous — name it "
                "(CGFloat.greatestFiniteMagnitude)",
            ))
    return findings


def main() -> int:
    targets = [Path(arg) for arg in sys.argv[1:]] or [ROOT / "MirrorCal", ROOT / "MirrorCalKit/Sources"]
    files = sorted(f for target in targets for f in target.rglob("*.swift"))
    if not files:
        print(f"no Swift files under {', '.join(str(t) for t in targets)}", file=sys.stderr)
        return 1

    all_lines = {path: path.read_text(encoding="utf-8", errors="replace").splitlines() for path in files}
    declared_types, codable_types = build_codable_type_index(all_lines)
    non_codable_types = declared_types - codable_types
    sendable_types = build_sendable_conforming_type_index(all_lines)

    total = 0
    for path in files:
        for line_number, source, message in check(path, all_lines[path], non_codable_types, sendable_types):
            total += 1
            print(f"::error file={path},line={line_number}::{message}")
            print(f"  {path}:{line_number}: {source}")

    if total:
        print(f"\n{total} known Swift 6 / SwiftUI trap(s) — each of these has failed a Mac run before")
        return 1
    print(f"no known Swift 6 / SwiftUI traps in {len(files)} files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
