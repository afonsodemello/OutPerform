//
//  GoogleClientID.swift
//  OutPerform
//
//  Holds the local Google OAuth iOS client ID. This file IS committed (so
//  fresh clones still compile), but the real value only ever lives on this
//  machine: after filling it in, run
//
//      git update-index --skip-worktree OutPerform/OutPerform/Health/GoogleClientID.swift
//
//  so git stops tracking edits to this file — `git status`/`git add -A` will
//  never see the real ID again. To resume tracking it, run
//  `git update-index --no-skip-worktree` on the same path.
//
//  Anyone else cloning the repo leaves this blank and either pastes their own
//  client ID here (without re-enabling tracking) or uses the in-app
//  "Connect Google Health" screen at runtime instead.
//

enum GoogleClientID {
    static let value = ""
}
