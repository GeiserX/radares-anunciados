import pytest

from radares_anunciados.streetnames import expand, same_street


@pytest.mark.parametrize(
    "written, full",
    [
        ("Avda. Padre Isla", "Avenida Padre Isla"),
        ("Avda Antibióticos", "Avenida Antibióticos"),
        ("Av. Universidad", "Avenida Universidad"),
        ("Pº Salamanca", "Paseo Salamanca"),
        ("Pº. Quintanilla", "Paseo Quintanilla"),
        ("Po. Papalaguinda", "Paseo Papalaguinda"),
        ("Ctra. Vilecha", "Carretera Vilecha"),
        ("C/Mayor", "Calle Mayor"),
        ("C/ Mayor", "Calle Mayor"),
        ("Cno. Tiñosa", "Camino Tiñosa"),
        ("Pza. Mayor", "Plaza Mayor"),
        ("Fdez. Ladreda.", "Fernández Ladreda"),
        ("Fdez Ladreda", "Fernández Ladreda"),
        ("Dr. Fleming", "Doctor Fleming"),
        ("Ing. Sáenz Miera", "Ingeniero Sáenz Miera"),
        ("Avda. Gran Vía\xa0 S. Marcos", "Avenida Gran Vía S. Marcos"),
        # full words are left alone
        ("Avenida de Europa", "Avenida de Europa"),
        ("Plaza Mayor", "Plaza Mayor"),
        ("Paseo de Salamanca", "Paseo de Salamanca"),
        ("Ingeniero Saez de Miera", "Ingeniero Saez de Miera"),
    ],
)
def test_expand(written, full):
    assert expand(written) == full


@pytest.mark.parametrize(
    "written, mapped",
    [
        ("José M. Suárez G.", "Calle José María Suárez González"),
        ("Joaquín G. Vecín", "Calle Joaquín González Vecín"),
        ("Ingeniero S. Miera", "Avenida Ingeniero Sáenz de Miera"),
        ("Pendón de Baeza", "Calle Pendón de Baeza"),
        ("Avenida Antibióticos", "Avenida de Los Antibióticos"),
        ("San Pedro de Castro", "Calle San Pedro del Castro"),
        ("Avenida Gran Vía S. Marcos", "Gran Vía de San Marcos"),
    ],
)
def test_same_street(written, mapped):
    assert same_street(written, mapped)


@pytest.mark.parametrize(
    "written, mapped",
    [
        ("Alcalde M. Castaño", "Calle Martín Castaño Unzúe"),  # a word more
        ("José M. Suárez G.", "Calle José Tejera Suárez"),
        ("M. G.", "Calle Mayor Grande"),  # initials alone match nothing
        ("Gutiérrez Mellado", "Calle General Gutiérrez Mellado"),  # left to the alias table
    ],
)
def test_not_same_street(written, mapped):
    assert not same_street(written, mapped)
