/*
 * ersub_clips.c — CLIPS Port wrapper for ErSub
 *
 * Protocol: NDJSON over stdin/stdout
 * Operations:
 *   {"op":"assert","facts":[...]}     — assert facts
 *   {"op":"run"}                      — run rules, output results
 *   {"op":"retract_all"}              — retract all facts (keep rules)
 *   {"op":"reload","files":["..."]}   — clear and reload rule files
 *   {"op":"ping"}                     — heartbeat
 *
 * Build: make -C c_src
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "clips_lib/clips.h"

#define MAX_LINE (1024 * 1024)  /* 1MB max line */
#define MAX_PATH_LEN 512

/* Simple JSON helpers (minimal, no dependency) */

static const char *json_get_string(const char *json, const char *key, char *buf, int buflen) {
    char pattern[256];
    snprintf(pattern, sizeof(pattern), "\"%s\":\"", key);
    const char *start = strstr(json, pattern);
    if (!start) return NULL;
    start += strlen(pattern);
    const char *end = strchr(start, '"');
    if (!end || (end - start) >= buflen) return NULL;
    int len = (int)(end - start);
    memcpy(buf, start, len);
    buf[len] = '\0';
    return buf;
}

static const char *json_get_array(const char *json, const char *key) {
    char pattern[256];
    snprintf(pattern, sizeof(pattern), "\"%s\":[", key);
    const char *start = strstr(json, pattern);
    if (!start) return NULL;
    return start + strlen(pattern) - 1; /* point at '[' */
}

/* Assert a fact string into CLIPS */
static void assert_fact_string(Environment *env, const char *factStr) {
    AssertString(env, factStr);
}

/* Collect all facts matching a template and output as JSON */
static void output_results(Environment *env) {
    /* Look for selection-result or billing-result or quota-check-result facts */
    Fact *fact;
    int found = 0;

    printf("{\"op\":\"result\",\"facts\":[");

    for (fact = GetNextFact(env, NULL); fact != NULL; fact = GetNextFact(env, fact)) {
        CLIPSValue cv;
        Deftemplate *tmpl = FactDeftemplate(fact);
        const char *name = DeftemplateName(tmpl);

        /* Skip internal CLIPS facts */
        if (strcmp(name, "initial-fact") == 0) continue;

        if (found > 0) printf(",");
        printf("{\"template\":\"%s\"", name);

        /* Extract slots dynamically */
        CLIPSValue slotNames;
        FactSlotNames(fact, &slotNames);
        if (slotNames.header->type == MULTIFIELD_TYPE) {
            size_t i;
            for (i = 0; i < slotNames.multifieldValue->length; i++) {
                CLIPSValue *entry = &slotNames.multifieldValue->contents[i];
                if (entry->header->type == SYMBOL_TYPE) {
                    const char *slotName = entry->lexemeValue->contents;
                    GetFactSlot(fact, slotName, &cv);
                    printf(",\"%s\":", slotName);
                    switch (cv.header->type) {
                        case INTEGER_TYPE:
                            printf("%lld", cv.integerValue->contents);
                            break;
                        case FLOAT_TYPE:
                            printf("%f", cv.floatValue->contents);
                            break;
                        case SYMBOL_TYPE:
                        case STRING_TYPE:
                            printf("\"%s\"", cv.lexemeValue->contents);
                            break;
                        default:
                            printf("null");
                            break;
                    }
                }
            }
        }

        printf("}");
        found++;
    }

    printf("]}\n");
    fflush(stdout);
}

/* Load rule files */
static int load_rules(Environment *env, const char *dir) {
    char path[MAX_PATH_LEN];
    const char *files[] = {
        "core.clp", "scheduling.clp", "billing.clp",
        "quota.clp", "account_status.clp", "model_routing.clp",
        "error_passthrough.clp", NULL
    };

    for (int i = 0; files[i] != NULL; i++) {
        snprintf(path, sizeof(path), "%s/%s", dir, files[i]);
        FILE *f = fopen(path, "r");
        if (f) {
            fclose(f);
            if (BatchStar(env, path) == 0) {
                fprintf(stderr, "Warning: failed to load %s\n", path);
            }
        }
        /* Skip missing files silently */
    }

    return 0;
}

int main(int argc, char *argv[]) {
    Environment *env = CreateEnvironment();
    char *line = malloc(MAX_LINE);
    char buf[MAX_PATH_LEN];

    if (!env || !line) {
        fprintf(stderr, "Failed to initialize CLIPS\n");
        return 1;
    }

    /* Load default rules */
    const char *rules_dir = argc > 1 ? argv[1] : "priv/clips";
    load_rules(env, rules_dir);

    /* Main loop: read NDJSON commands from stdin */
    while (fgets(line, MAX_LINE, stdin) != NULL) {
        /* Remove trailing newline */
        size_t len = strlen(line);
        if (len > 0 && line[len-1] == '\n') line[len-1] = '\0';
        if (strlen(line) == 0) continue;

        /* Parse operation */
        if (json_get_string(line, "op", buf, sizeof(buf)) == NULL) {
            fprintf(stderr, "Missing 'op' field\n");
            continue;
        }

        if (strcmp(buf, "assert") == 0) {
            /* Assert facts from the "facts" array */
            /* Each fact is a CLIPS fact string in "assert_string" field */
            const char *facts = json_get_array(line, "facts");
            if (facts) {
                /* Parse array of strings - handles JSON-escaped quotes */
                const char *p = facts;
                char assertStr[4096];
                while ((p = strstr(p, "\"assert_string\":\"")) != NULL) {
                    p += strlen("\"assert_string\":\"");
                    /* Find end quote, skipping escaped \" */
                    int i = 0;
                    while (*p && i < (int)sizeof(assertStr) - 1) {
                        if (*p == '\\' && *(p+1) == '"') {
                            /* JSON escaped quote → CLIPS double quote */
                            assertStr[i++] = '"';
                            p += 2;
                        } else if (*p == '"') {
                            /* Unescaped quote = end of JSON string */
                            break;
                        } else {
                            assertStr[i++] = *p++;
                        }
                    }
                    assertStr[i] = '\0';
                    if (i > 0) {
                        assert_fact_string(env, assertStr);
                    }
                    if (*p == '"') p++;
                }
            }
            printf("{\"op\":\"ok\"}\n");
            fflush(stdout);

        } else if (strcmp(buf, "run") == 0) {
            /* Run the inference engine */
            Run(env, -1);
            output_results(env);

        } else if (strcmp(buf, "retract_all") == 0) {
            /* Reset facts but keep rules */
            Reset(env);
            printf("{\"op\":\"ok\"}\n");
            fflush(stdout);

        } else if (strcmp(buf, "reload") == 0) {
            /* Clear everything and reload rules */
            Clear(env);
            char dir[MAX_PATH_LEN];
            if (json_get_string(line, "dir", dir, sizeof(dir))) {
                load_rules(env, dir);
            } else {
                load_rules(env, rules_dir);
            }
            printf("{\"op\":\"ok\"}\n");
            fflush(stdout);

        } else if (strcmp(buf, "ping") == 0) {
            printf("{\"op\":\"pong\"}\n");
            fflush(stdout);

        } else {
            fprintf(stderr, "Unknown op: %s\n", buf);
            printf("{\"op\":\"error\",\"message\":\"unknown op\"}\n");
            fflush(stdout);
        }
    }

    free(line);
    DestroyEnvironment(env);
    return 0;
}
