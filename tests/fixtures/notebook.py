import marimo

app = marimo.App()


@app.cell
def __(mo):
    x = 1
    print("hello from cell 1")
    return x


@app.cell
def __(x):
    y = x + 2
    print(f"value: {y}")
    return y


@app.cell
def __(y):
    z = y + 3
    print(f"final: {z}")
    return (
        y,
        z,
    )


@app.cell
def __(
    y,
    z,
):
    print(f"multiline args: {y + z}")
    return


if __name__ == "__main__":
    app.run()
