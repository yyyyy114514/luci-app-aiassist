// LuCI AI Assistant - background worker (ucode)
// Path: /usr/libexec/aiassist/worker.uc
// Runs asynchronously so long AI calls never block rpcd threads.
// Usage: ucode worker.uc <sid> <jobid>
// Licensed under the Apache License 2.0.

'use strict';

import { unlink } from 'fs';
import { read_job, write_job, run_job, unlock_session } from 'aiassist.core';

let sid   = ARGV[1];
let jobid = ARGV[2];

let job = read_job(jobid);
if (!job)
	exit(1);

job.status = 'running';
job.started = time();
write_job(job);

let res = run_job(job);

// reload job in case it was modified meanwhile
job = read_job(jobid) || job;

if (res.error) {
	job.status = 'error';
	job.error = res.error;
}
else {
	job.status = 'done';
	job.reply = res.reply;
	job.tools = res.tools || [];
	if (res.compress)
		job.compress = res.compress;
}

job.done_ts = time();
write_job(job);

// cleanup
unlink('/etc/aiassist/jobs/' + jobid + '.stop');
unlock_session(sid);
