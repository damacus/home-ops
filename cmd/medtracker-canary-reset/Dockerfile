FROM scratch
COPY --chmod=0555 dist/medtracker-canary-reset /medtracker-canary-reset
USER 65532:65532
ENTRYPOINT ["/medtracker-canary-reset"]
