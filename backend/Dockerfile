# Builds the zero-dependency Go backend into a small runtime image. This
# file is what makes the backend containerizable; it adds nothing to go.mod
# and changes nothing about the binary itself - see docs/runtime-isolation.md
# for why containers exist at all (per-worktree isolation, not packaging).
FROM golang:1.26-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY *.go ./
RUN CGO_ENABLED=0 go build -o /out/inkwell-backend .

# git is a hard runtime requirement (store.go shells out to the system
# binary), not a build-time one - it has to live in the final image too.
FROM alpine:3.20
RUN apk add --no-cache git && \
    adduser -D -H -u 10001 inkwell
COPY --from=build /out/inkwell-backend /usr/local/bin/inkwell-backend
USER inkwell
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/inkwell-backend"]
