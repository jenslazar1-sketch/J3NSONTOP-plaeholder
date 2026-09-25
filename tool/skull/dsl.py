SWAP = str.maketrans({'/':'\\','\\':'/','(':')',')':'(','[':']',']':'[','{':'}','}':'{','<':'>','>':'<'})
W = 41; C = 20
def row(*placements):
    cells = [' '] * (C + 1)
    for col, s in placements:
        for i, ch in enumerate(s):
            if col + i > C: raise ValueError(f'overflow {placements}')
            cells[col + i] = ch
    left = ''.join(cells)
    return (left + left[:C][::-1].translate(SWAP)).rstrip()
def build(rows):
    return [row(*r) for r in rows]
