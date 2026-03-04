FROM golang:1.22-alpine AS builder
WORKDIR /app
COPY go.mod .
COPY main.go .
RUN go build -o fog-service .

FROM alpine:3.19
WORKDIR /app
COPY --from=builder /app/fog-service .
EXPOSE 8444 8445
CMD ["/app/fog-service"]
