//! matchconf — A general-purpose ssh_config-style configuration library.
//!
//! matchconf extracts the ssh_config configuration format into a reusable system.
//! Consumers register their own section keywords, directives, token expanders,
//! and match conditions. The library handles parsing, pattern matching,
//! first-match-wins semantics, type coercion, and diagnostics.

const std = @import("std");

pub const parser = @import("parser.zig");
pub const lookup_mod = @import("lookup.zig");
pub const glob = @import("glob.zig");
pub const types = @import("types.zig");
pub const diagnostics = @import("diagnostics.zig");
pub const expand = @import("expand.zig");
pub const include = @import("include.zig");
pub const line_parser = @import("line_parser.zig");

// Re-export primary types for convenience
pub const Parser = parser.Parser;
pub const Config = parser.Config;
pub const Section = parser.Section;
pub const SectionKind = parser.SectionKind;
pub const SectionConfig = parser.SectionConfig;
pub const MatchingMode = parser.MatchingMode;
pub const DirectiveDef = parser.DirectiveDef;
pub const ParsedDirective = parser.ParsedDirective;
pub const MatchCriteria = parser.MatchCriteria;
pub const ExpandContext = parser.ExpandContext;
pub const ExpanderFn = parser.ExpanderFn;
pub const MatcherFn = parser.MatcherFn;

pub const LookupResult = lookup_mod.LookupResult;
pub const ResolvedValue = lookup_mod.ResolvedValue;

pub const Diagnostic = diagnostics.Diagnostic;
pub const DiagnosticList = diagnostics.DiagnosticList;
pub const Level = diagnostics.Level;

pub const ValueType = types.ValueType;
pub const Value = types.Value;
pub const StringPair = types.StringPair;

/// Perform a lookup against the config for the given target.
pub const lookupFn = lookup_mod.lookup;

/// Expand all %X tokens in a string value.
pub const expandTokens = expand.expandTokens;

test {
    // Pull in all module tests
    std.testing.refAllDecls(@This());
}
