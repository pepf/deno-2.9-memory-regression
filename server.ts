// Minimal HTTP server whose ONLY purpose is to pull in a realistic,
// npm-dominant module graph with a couple of `jsr:` deps mixed in — the same
// *shape* as a real Deno backend (Apollo + Express + Drizzle + pg + a logger),
// without any proprietary code.
//
// This composition (heavy npm graph + jsr islands) is what triggers
// https://github.com/denoland/deno/issues/35664 under `deno run --watch`.
//
// The imports below are only referenced (not really wired together) — importing
// them is enough to instantiate the node-compat module graph, which is what the
// runtime retains.

import express from "express";
import { ApolloServer } from "@apollo/server";
import { buildSubgraphSchema } from "@apollo/subgraph";
import { drizzle } from "drizzle-orm/node-postgres";
import pg from "pg";
import { parse } from "graphql";
import pino from "pino";
import ky from "ky";

// jsr: deps — make this a MIXED npm+jsr graph (the vulnerable composition).
import * as jose from "@panva/jose";
import { encodeBase64 } from "@std/encoding/base64";

const log = pino();

// Touch every import so nothing is dead-code-eliminated and each graph is
// actually instantiated.
void [express, ApolloServer, buildSubgraphSchema, drizzle, pg, parse, ky, jose];

Deno.serve(
  {
    port: 8000,
    onListen: () => log.info("running on http://localhost:8000"),
  },
  () => new Response(encodeBase64("ok")),
);

// Keep the process alive and idle so we can sample steady-state RSS.
setInterval(() => {}, 1000);
